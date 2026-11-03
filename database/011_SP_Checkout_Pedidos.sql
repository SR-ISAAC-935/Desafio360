-- 011_SP_Checkout_Pedidos.sql
-- Reserva de existencia, creación atómica e idempotente del pedido, consulta, avance de estados,
-- cancelación y devoluciones (por línea, con TVP).
--
-- Concurrencia: las filas de VariantesProducto se bloquean con UPDLOCK/HOLDLOCK. Si dos transacciones
-- se bloquean en orden cruzado SQL Server puede abortar una con el error 1205 (deadlock): el backend
-- debe reintentar esas solicitudes (una o dos veces) antes de responder error.

------------------------------------------------------------------
-- Bloquea las variantes de un carrito SIEMPRE en orden ascendente de IDVariante.
-- Con el mismo orden en todas las transacciones se evitan los deadlocks entre carritos que
-- comparten productos. Debe llamarse dentro de una transacción (los bloqueos duran hasta su fin).
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Inventario_BloquearVariantes
    @IDCarrito INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @@TRANCOUNT = 0
        THROW 50199, N'SP_Inventario_BloquearVariantes debe ejecutarse dentro de una transacción.', 1;

    DECLARE @ID INT = 0, @Bloqueada INT;

    WHILE 1 = 1
    BEGIN
        SELECT TOP (1) @ID = cd.IDVariante
        FROM CarritoDetalle cd
        WHERE cd.IDCarrito = @IDCarrito AND cd.IDVariante > @ID
        ORDER BY cd.IDVariante;

        IF @@ROWCOUNT = 0 BREAK;

        SELECT @Bloqueada = IDVariante FROM VariantesProducto WITH (UPDLOCK, HOLDLOCK) WHERE IDVariante = @ID;
    END;
END;
GO

------------------------------------------------------------------
-- Inicio del pago: reserva la existencia de cada variante del carrito por @MinutosReserva
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Inventario_ReservarExistencia
    @IDCarrito      INT,
    @IDUsuario      INT,
    @MinutosReserva INT = 15
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET LOCK_TIMEOUT 15000;

    IF @MinutosReserva IS NULL OR @MinutosReserva < 1 OR @MinutosReserva > 60
        SET @MinutosReserva = 15;

    EXEC SP_Carrito_ValidarPropietario @IDCarrito, @IDUsuario, NULL, 1;

    IF NOT EXISTS (SELECT 1 FROM CarritoDetalle WHERE IDCarrito = @IDCarrito)
        THROW 50173, N'El carrito está vacío.', 1;

    DECLARE @Ahora DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @Vence DATETIME2(0) = DATEADD(MINUTE, @MinutosReserva, @Ahora);
    DECLARE @SKU VARCHAR(50), @Disp INT, @Msg NVARCHAR(200);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Se liberan las reservas previas de este carrito y las vencidas
        UPDATE ReservasExistencia SET Estado = 'LIBERADA' WHERE IDCarrito = @IDCarrito AND Estado = 'ACTIVA';
        UPDATE ReservasExistencia SET Estado = 'VENCIDA' WHERE Estado = 'ACTIVA' AND FechaVencimiento <= @Ahora;

        -- Bloqueo de las variantes del carrito (en orden fijo): dos clientes por la última unidad se atienden uno por uno
        EXEC SP_Inventario_BloquearVariantes @IDCarrito;

        IF EXISTS (SELECT 1
                   FROM CarritoDetalle cd
                   JOIN VariantesProducto v ON v.IDVariante = cd.IDVariante
                   JOIN Productos p ON p.IDProducto = v.IDProducto
                   JOIN Categorias c ON c.IDCategoria = p.IDCategoria
                   WHERE cd.IDCarrito = @IDCarrito AND (v.Activo = 0 OR p.Activo = 0 OR c.Activo = 0))
            THROW 50171, N'El carrito contiene productos que ya no están disponibles.', 1;

        SELECT TOP (1) @SKU = v.SKU, @Disp = d.Disponible
        FROM CarritoDetalle cd
        JOIN VariantesProducto v ON v.IDVariante = cd.IDVariante
        JOIN FU_Inventario_Disponibilidad(NULL) d ON d.IDVariante = cd.IDVariante
        WHERE cd.IDCarrito = @IDCarrito AND cd.Cantidad > d.Disponible
        ORDER BY v.SKU;

        IF @SKU IS NOT NULL
        BEGIN
            SET @Msg = CONCAT(N'No hay existencia suficiente de ', @SKU, N'. Disponible: ',
                              CASE WHEN @Disp < 0 THEN 0 ELSE @Disp END, N'.');
            THROW 50172, @Msg, 1;
        END;

        INSERT INTO ReservasExistencia (IDCarrito, IDVariante, Cantidad, Estado, FechaCreacion, FechaVencimiento, PrecioUnitario)
        SELECT cd.IDCarrito, cd.IDVariante, cd.Cantidad, 'ACTIVA', @Ahora, @Vence, v.Precio
        FROM CarritoDetalle cd
        JOIN VariantesProducto v ON v.IDVariante = cd.IDVariante
        WHERE cd.IDCarrito = @IDCarrito;

        UPDATE Carritos SET FechaUltimaActividad = @Ahora WHERE IDCarrito = @IDCarrito;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT r.IDReserva, v.SKU, r.Cantidad, r.FechaVencimiento
    FROM ReservasExistencia r
    JOIN VariantesProducto v ON v.IDVariante = r.IDVariante
    WHERE r.IDCarrito = @IDCarrito AND r.Estado = 'ACTIVA'
    ORDER BY v.SKU;
END;
GO

------------------------------------------------------------------
-- Consulta de un pedido (cliente: solo los suyos; Operador/Administrador: cualquiera)
-- Devuelve 4 conjuntos: encabezado, líneas, historial de estados y pagos.
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Pedidos_ObtenerDetalle
    @IDPedido             INT,
    @IDUsuarioSolicitante INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Dueno INT = (SELECT IDUsuario FROM Pedidos WHERE IDPedido = @IDPedido);
    IF @Dueno IS NULL
        THROW 50184, N'El pedido no existe.', 1;

    DECLARE @EsPersonal BIT = CASE WHEN EXISTS (
        SELECT 1 FROM Usuarios u JOIN Roles r ON r.IDRol = u.IDRol
        WHERE u.IDUsuario = @IDUsuarioSolicitante AND u.Activo = 1
          AND r.NombreRol IN (N'Administrador', N'Operador')) THEN 1 ELSE 0 END;

    IF @EsPersonal = 0 AND @Dueno <> @IDUsuarioSolicitante
        THROW 50183, N'No tiene acceso a este pedido.', 1;

    SELECT p.IDPedido, p.IDUsuario, u.NombreCompleto AS Cliente, u.Email, e.NombreEstado AS Estado,
           p.Subtotal, p.Descuento, p.Total, p.MontoIVA, cu.Codigo AS CodigoCupon, p.FechaPedido,
           CONCAT(d.Direccion, CASE WHEN d.Zona IS NULL THEN N'' ELSE CONCAT(N', zona ', d.Zona) END,
                  N', ', d.Municipio, N', ', d.Departamento) AS DireccionEntrega
    FROM Pedidos p
    JOIN Usuarios u ON u.IDUsuario = p.IDUsuario
    JOIN EstadosPedido e ON e.IDEstadoPedido = p.IDEstadoPedido
    JOIN Direcciones d ON d.IDDireccion = p.IDDireccion
    LEFT JOIN Cupones cu ON cu.IDCupon = p.IDCupon
    WHERE p.IDPedido = @IDPedido;

    SELECT pd.IDPedidoDetalle, v.SKU, pr.NombreProducto, v.Talla, v.Color, pd.Cantidad, pd.PrecioUnitario,
           pd.DescuentoLinea, pd.TotalLinea, pd.CantidadDevuelta
    FROM PedidoDetalle pd
    JOIN VariantesProducto v ON v.IDVariante = pd.IDVariante
    JOIN Productos pr ON pr.IDProducto = v.IDProducto
    WHERE pd.IDPedido = @IDPedido
    ORDER BY pr.NombreProducto, v.SKU;

    SELECT h.FechaCambio, ea.NombreEstado AS EstadoAnterior, en.NombreEstado AS EstadoNuevo,
           us.NombreCompleto AS Usuario, h.Comentario
    FROM HistorialEstadosPedido h
    LEFT JOIN EstadosPedido ea ON ea.IDEstadoPedido = h.IDEstadoAnterior
    JOIN EstadosPedido en ON en.IDEstadoPedido = h.IDEstadoNuevo
    JOIN Usuarios us ON us.IDUsuario = h.IDUsuario
    WHERE h.IDPedido = @IDPedido
    ORDER BY h.FechaCambio, h.IDHistorial;

    SELECT IDPago, Monto, Metodo, Estado, Referencia, FechaPago
    FROM Pagos
    WHERE IDPedido = @IDPedido
    ORDER BY IDPago;
END;
GO

------------------------------------------------------------------
-- Creación del pedido + pago (simulado). ATÓMICO e IDEMPOTENTE.
--  * Lee las líneas desde el carrito en la base de datos: el cliente no envía precios ni cantidades.
--  * Repetir la misma @LlaveIdempotencia devuelve el pedido ya creado (Repetido = 1): ni dos
--    pedidos ni dos cobros, aunque se repita al mismo tiempo (se serializa con un bloqueo de aplicación).
--  * El backend llama a este procedimiento después de que el pago simulado fue aprobado.
--  * Todo o nada: pedido, detalle, kardex, cupón, pago, historial y reservas en una transacción.
-- Primer conjunto de resultados: IDPedido y Repetido; luego, el detalle del pedido.
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Pedidos_CrearPedido
    @IDUsuario         INT,
    @IDCarrito         INT,
    @IDDireccion       INT,
    @LlaveIdempotencia VARCHAR(64),
    @MetodoPago        VARCHAR(30) = 'SIMULADO',
    @ReferenciaPago    VARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET LOCK_TIMEOUT 15000;

    IF @LlaveIdempotencia IS NULL OR LEN(LTRIM(RTRIM(@LlaveIdempotencia))) < 8
        THROW 50126, N'La llave de idempotencia es obligatoria (mínimo 8 caracteres).', 1;

    DECLARE @IDPedido INT, @Repetido BIT = 0;

    -- Camino rápido: la solicitud ya se procesó antes
    SELECT @IDPedido = IDPedido FROM Pedidos WHERE IDUsuario = @IDUsuario AND LlaveIdempotencia = @LlaveIdempotencia;
    IF @IDPedido IS NOT NULL
    BEGIN
        SELECT @IDPedido AS IDPedido, CAST(1 AS BIT) AS Repetido;
        EXEC SP_Pedidos_ObtenerDetalle @IDPedido, @IDUsuario;
        RETURN;
    END;

    EXEC SP_Carrito_ValidarPropietario @IDCarrito, @IDUsuario, NULL, 1;

    IF NOT EXISTS (SELECT 1 FROM Direcciones WHERE IDDireccion = @IDDireccion)
        THROW 50181, N'La dirección de entrega no existe.', 1;
    IF NOT EXISTS (SELECT 1 FROM Direcciones WHERE IDDireccion = @IDDireccion AND IDUsuario = @IDUsuario)
        THROW 50182, N'La dirección no pertenece al cliente.', 1;
    IF NOT EXISTS (SELECT 1 FROM Direcciones WHERE IDDireccion = @IDDireccion AND IDUsuario = @IDUsuario AND Activo = 1)
        THROW 50181, N'La dirección de entrega está inactiva.', 1;

    DECLARE @EstPendiente INT = (SELECT IDEstadoPedido FROM EstadosPedido WHERE NombreEstado = N'Pendiente de pago');
    DECLARE @EstPagado INT = (SELECT IDEstadoPedido FROM EstadosPedido WHERE NombreEstado = N'Pagado');
    DECLARE @Recurso NVARCHAR(255) = CONCAT(N'pedido:', @IDUsuario, N':', @LlaveIdempotencia);
    DECLARE @Lock INT, @NumLineasCarrito INT, @NumLineas INT;
    DECLARE @IDCupon INT, @Codigo VARCHAR(50), @IDCuponValidado INT, @Descuento DECIMAL(18,2) = 0;
    DECLARE @Subtotal DECIMAL(18,2), @Total DECIMAL(18,2), @IVA DECIMAL(18,2), @Base DECIMAL(18,2), @Resto DECIMAL(18,2);
    DECLARE @LimiteCliente INT, @UsosCliente INT, @LlavePago VARCHAR(64), @Json NVARCHAR(MAX);

    CREATE TABLE #Lineas (
        IDVariante     INT           NOT NULL PRIMARY KEY,
        IDCategoria    INT           NOT NULL,
        Cantidad       INT           NOT NULL,
        PrecioUnitario DECIMAL(18,2) NOT NULL,
        Bruto          DECIMAL(18,2) NOT NULL,
        Aplica         BIT           NOT NULL DEFAULT 0,
        DescuentoLinea DECIMAL(18,2) NOT NULL DEFAULT 0
    );
    CREATE TABLE #Mov (IDVariante INT NOT NULL, Cantidad INT NOT NULL, ExistenciaResultante INT NOT NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Serializa solicitudes con la misma llave (doble clic / reintento simultáneo)
        EXEC @Lock = sp_getapplock @Resource = @Recurso, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 10000;
        IF @Lock < 0
            THROW 50190, N'No se pudo procesar la solicitud en este momento. Intente de nuevo.', 1;

        -- Si otra solicitud igual terminó mientras esperábamos, devolvemos su pedido
        SELECT @IDPedido = IDPedido FROM Pedidos WHERE IDUsuario = @IDUsuario AND LlaveIdempotencia = @LlaveIdempotencia;

        IF @IDPedido IS NOT NULL
        BEGIN
            SET @Repetido = 1;
        END
        ELSE
        BEGIN
            -- Bloqueo ordenado de las variantes y lectura de las líneas; el precio sale siempre de la base de datos
            EXEC SP_Inventario_BloquearVariantes @IDCarrito;
            SELECT @NumLineasCarrito = COUNT(*) FROM CarritoDetalle WHERE IDCarrito = @IDCarrito;

            INSERT INTO #Lineas (IDVariante, IDCategoria, Cantidad, PrecioUnitario, Bruto)
            SELECT v.IDVariante, p.IDCategoria, cd.Cantidad, v.Precio, CAST(cd.Cantidad * v.Precio AS DECIMAL(18,2))
            FROM CarritoDetalle cd
            JOIN VariantesProducto v WITH (UPDLOCK, HOLDLOCK) ON v.IDVariante = cd.IDVariante
            JOIN Productos p ON p.IDProducto = v.IDProducto
            JOIN Categorias c ON c.IDCategoria = p.IDCategoria
            WHERE cd.IDCarrito = @IDCarrito AND v.Activo = 1 AND p.Activo = 1 AND c.Activo = 1;

            SELECT @NumLineas = COUNT(*) FROM #Lineas;

            IF @NumLineasCarrito = 0
                THROW 50173, N'El carrito está vacío.', 1;
            IF @NumLineas <> @NumLineasCarrito
                THROW 50171, N'El carrito contiene productos que ya no están disponibles.', 1;

            -- Cada línea debe tener su reserva vigente (se crea al iniciar el pago)
            IF EXISTS (SELECT 1 FROM #Lineas l
                       WHERE NOT EXISTS (SELECT 1 FROM ReservasExistencia r
                                         WHERE r.IDCarrito = @IDCarrito AND r.IDVariante = l.IDVariante
                                           AND r.Estado = 'ACTIVA' AND r.FechaVencimiento > SYSUTCDATETIME()
                                           AND r.Cantidad >= l.Cantidad))
                THROW 50174, N'La reserva de existencia venció o no existe. Inicie el pago nuevamente.', 1;

            -- El cliente paga el precio que vio al iniciar el pago: si cambió, se pide reiniciar
            IF EXISTS (SELECT 1 FROM #Lineas l
                       JOIN ReservasExistencia r ON r.IDCarrito = @IDCarrito AND r.IDVariante = l.IDVariante AND r.Estado = 'ACTIVA'
                       WHERE r.PrecioUnitario IS NULL OR r.PrecioUnitario <> l.PrecioUnitario)
                THROW 50175, N'El precio de un producto cambió. Revise su carrito e inicie el pago nuevamente.', 1;

            SELECT @Subtotal = SUM(Bruto) FROM #Lineas;

            -- Cupón: validación con mensaje específico, consumo atómico y descuento por línea
            SELECT @IDCupon = IDCupon FROM Carritos WHERE IDCarrito = @IDCarrito;

            IF @IDCupon IS NOT NULL
            BEGIN
                SELECT @Codigo = Codigo, @LimiteCliente = LimiteUsosPorCliente FROM Cupones WHERE IDCupon = @IDCupon;

                EXEC SP_Cupones_Validar @IDCarrito, @IDUsuario, @Codigo, @IDCuponValidado OUTPUT, @Descuento OUTPUT;

                -- Consumo atómico: aunque varios clientes lo usen a la vez, nunca se pasa del límite total
                UPDATE Cupones
                SET UsosActuales = UsosActuales + 1
                WHERE IDCupon = @IDCupon AND Activo = 1 AND UsosActuales < LimiteUsosTotal;
                IF @@ROWCOUNT = 0
                    THROW 50155, N'El cupón está agotado.', 1;

                -- Con la fila del cupón bloqueada se revisa el límite por cliente sin carreras
                SELECT @UsosCliente = COUNT(*) FROM UsosCupon WHERE IDCupon = @IDCupon AND IDUsuario = @IDUsuario;
                IF @UsosCliente >= @LimiteCliente
                    THROW 50157, N'Ya usó este cupón el máximo de veces permitido.', 1;

                UPDATE l
                SET Aplica = CASE WHEN c.IDCategoria IS NULL OR l.IDCategoria = c.IDCategoria THEN 1 ELSE 0 END
                FROM #Lineas l
                CROSS JOIN Cupones c
                WHERE c.IDCupon = @IDCupon;

                SELECT @Base = SUM(Bruto) FROM #Lineas WHERE Aplica = 1;

                UPDATE #Lineas
                SET DescuentoLinea = CAST(ROUND(@Descuento * Bruto / @Base, 2) AS DECIMAL(18,2))
                WHERE Aplica = 1;

                -- El redondeo por línea puede dejar centavos de diferencia: se ajusta en la línea mayor
                SELECT @Resto = @Descuento - SUM(DescuentoLinea) FROM #Lineas;
                IF @Resto <> 0
                BEGIN
                    ;WITH Mayor AS (
                        SELECT TOP (1) DescuentoLinea FROM #Lineas WHERE Aplica = 1 ORDER BY Bruto DESC, IDVariante
                    )
                    UPDATE Mayor SET DescuentoLinea = DescuentoLinea + @Resto;
                END;
            END;

            SET @Total = @Subtotal - @Descuento;
            SET @IVA = CAST(ROUND(@Total * 12 / 112, 2) AS DECIMAL(18,2));

            -- Pedido (nace en "Pendiente de pago" y pasa a "Pagado" con su historial)
            INSERT INTO Pedidos (IDUsuario, IDDireccion, IDEstadoPedido, IDCupon, Subtotal, Descuento, Total, MontoIVA, LlaveIdempotencia)
            VALUES (@IDUsuario, @IDDireccion, @EstPendiente, @IDCupon, @Subtotal, @Descuento, @Total, @IVA, @LlaveIdempotencia);
            SET @IDPedido = SCOPE_IDENTITY();

            INSERT INTO PedidoDetalle (IDPedido, IDVariante, Cantidad, PrecioUnitario, DescuentoLinea, TotalLinea)
            SELECT @IDPedido, IDVariante, Cantidad, PrecioUnitario, DescuentoLinea, Bruto - DescuentoLinea
            FROM #Lineas;

            INSERT INTO HistorialEstadosPedido (IDPedido, IDEstadoAnterior, IDEstadoNuevo, IDUsuario, Comentario)
            VALUES (@IDPedido, NULL, @EstPendiente, @IDUsuario, N'Pedido creado');

            -- Salida de inventario con su movimiento en el kardex
            UPDATE v
            SET v.ExistenciaFisica = v.ExistenciaFisica - l.Cantidad
            OUTPUT inserted.IDVariante, -l.Cantidad, inserted.ExistenciaFisica
            INTO #Mov (IDVariante, Cantidad, ExistenciaResultante)
            FROM VariantesProducto v
            JOIN #Lineas l ON l.IDVariante = v.IDVariante;

            INSERT INTO MovimientosInventario (IDVariante, IDUsuario, TipoMovimiento, Cantidad, ExistenciaResultante, Motivo, IDPedido)
            SELECT IDVariante, @IDUsuario, 'SALIDA', Cantidad, ExistenciaResultante,
                   CONCAT(N'Venta - pedido #', @IDPedido), @IDPedido
            FROM #Mov;

            UPDATE ReservasExistencia SET Estado = 'CONFIRMADA', IDPedido = @IDPedido
            WHERE IDCarrito = @IDCarrito AND Estado = 'ACTIVA';

            IF @IDCupon IS NOT NULL
                INSERT INTO UsosCupon (IDCupon, IDUsuario, IDPedido) VALUES (@IDCupon, @IDUsuario, @IDPedido);

            -- Pago simulado aprobado (con total cero no hay cobro)
            IF @Total > 0
            BEGIN
                SET @LlavePago = CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', CONCAT(@IDUsuario, ':', @LlaveIdempotencia)), 2);
                INSERT INTO Pagos (IDPedido, Monto, Metodo, Estado, Referencia, LlaveIdempotencia)
                VALUES (@IDPedido, @Total, @MetodoPago, 'APROBADO',
                        ISNULL(@ReferenciaPago, CONCAT('SIM-', @IDPedido)), @LlavePago);
            END;

            UPDATE Pedidos SET IDEstadoPedido = @EstPagado WHERE IDPedido = @IDPedido;
            INSERT INTO HistorialEstadosPedido (IDPedido, IDEstadoAnterior, IDEstadoNuevo, IDUsuario, Comentario)
            VALUES (@IDPedido, @EstPendiente, @EstPagado, @IDUsuario, N'Pago aprobado');

            UPDATE Carritos SET Estado = 'CONVERTIDO', FechaUltimaActividad = SYSUTCDATETIME() WHERE IDCarrito = @IDCarrito;

            SET @Json = (SELECT IDPedido, IDUsuario, IDDireccion, IDCupon, Subtotal, Descuento, Total, MontoIVA
                         FROM Pedidos WHERE IDPedido = @IDPedido FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            EXEC SP_Bitacora_Registrar @IDUsuario, 'Pedidos', 'Pedidos', @IDPedido, 'CREAR', NULL, @Json;
        END;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @IDPedido AS IDPedido, @Repetido AS Repetido;
    EXEC SP_Pedidos_ObtenerDetalle @IDPedido, @IDUsuario;
END;
GO

------------------------------------------------------------------
-- Listados con filtros, orden y paginación del lado del servidor
-- @Ordenar: FECHA_DESC | FECHA_ASC | TOTAL_DESC | TOTAL_ASC
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Pedidos_Listar
    @IDUsuarioSolicitante INT,
    @IDEstadoPedido       INT = NULL,
    @IDCliente            INT = NULL,
    @BuscarCliente        NVARCHAR(100) = NULL,
    @Desde                DATE = NULL,
    @Hasta                DATE = NULL,
    @Ordenar              VARCHAR(12) = 'FECHA_DESC',
    @Pagina               INT = 1,
    @TamanoPagina         INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioSolicitante, 'PERSONAL';

    SET @Pagina = CASE WHEN @Pagina IS NULL OR @Pagina < 1 THEN 1 ELSE @Pagina END;
    SET @TamanoPagina = CASE WHEN @TamanoPagina IS NULL OR @TamanoPagina < 1 THEN 20
                             WHEN @TamanoPagina > 100 THEN 100 ELSE @TamanoPagina END;

    DECLARE @DesdeUTC DATETIME2(0) = NULL, @HastaUTC DATETIME2(0) = NULL, @Patron NVARCHAR(220) = NULL;
    IF @Desde IS NOT NULL
        SET @DesdeUTC = CAST(CAST(@Desde AS DATETIME2(0)) AT TIME ZONE 'Central America Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(0));
    IF @Hasta IS NOT NULL
        SET @HastaUTC = CAST(CAST(DATEADD(DAY, 1, @Hasta) AS DATETIME2(0)) AT TIME ZONE 'Central America Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(0));
    IF @BuscarCliente IS NOT NULL AND LEN(LTRIM(RTRIM(@BuscarCliente))) > 0
        SET @Patron = N'%' + REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@BuscarCliente)),
                      N'\', N'\\'), N'%', N'\%'), N'_', N'\_'), N'[', N'\[') + N'%';

    SELECT p.IDPedido, p.IDUsuario, u.NombreCompleto AS Cliente, u.Email, e.NombreEstado AS Estado,
           p.Total, p.FechaPedido,
           COUNT(*) OVER() AS TotalRegistros
    FROM Pedidos p
    JOIN Usuarios u ON u.IDUsuario = p.IDUsuario
    JOIN EstadosPedido e ON e.IDEstadoPedido = p.IDEstadoPedido
    WHERE (@IDEstadoPedido IS NULL OR p.IDEstadoPedido = @IDEstadoPedido)
      AND (@IDCliente IS NULL OR p.IDUsuario = @IDCliente)
      AND (@Patron IS NULL OR u.NombreCompleto LIKE @Patron ESCAPE N'\' OR u.Email LIKE @Patron ESCAPE N'\')
      AND (@DesdeUTC IS NULL OR p.FechaPedido >= @DesdeUTC)
      AND (@HastaUTC IS NULL OR p.FechaPedido < @HastaUTC)
    ORDER BY
        CASE WHEN @Ordenar = 'FECHA_ASC'  THEN p.FechaPedido END ASC,
        CASE WHEN @Ordenar = 'TOTAL_ASC'  THEN p.Total END ASC,
        CASE WHEN @Ordenar = 'TOTAL_DESC' THEN p.Total END DESC,
        p.FechaPedido DESC,
        p.IDPedido DESC
    OFFSET (@Pagina - 1) * @TamanoPagina ROWS FETCH NEXT @TamanoPagina ROWS ONLY;
END;
GO

CREATE OR ALTER PROCEDURE SP_Pedidos_ListarPorCliente
    @IDUsuario      INT,
    @IDEstadoPedido INT = NULL,
    @Pagina         INT = 1,
    @TamanoPagina   INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    SET @Pagina = CASE WHEN @Pagina IS NULL OR @Pagina < 1 THEN 1 ELSE @Pagina END;
    SET @TamanoPagina = CASE WHEN @TamanoPagina IS NULL OR @TamanoPagina < 1 THEN 20
                             WHEN @TamanoPagina > 100 THEN 100 ELSE @TamanoPagina END;

    SELECT p.IDPedido, e.NombreEstado AS Estado, p.Total, p.FechaPedido,
           COUNT(*) OVER() AS TotalRegistros
    FROM Pedidos p
    JOIN EstadosPedido e ON e.IDEstadoPedido = p.IDEstadoPedido
    WHERE p.IDUsuario = @IDUsuario
      AND (@IDEstadoPedido IS NULL OR p.IDEstadoPedido = @IDEstadoPedido)
    ORDER BY p.FechaPedido DESC, p.IDPedido DESC
    OFFSET (@Pagina - 1) * @TamanoPagina ROWS FETCH NEXT @TamanoPagina ROWS ONLY;
END;
GO

------------------------------------------------------------------
-- Avance de estado por el Operador/Administrador (preparar, despachar, entregar).
-- Pagado, Cancelado y Devuelto tienen sus propias rutas (pago, cancelación y devolución).
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Pedidos_AvanzarEstado
    @IDPedido        INT,
    @NuevoEstado     NVARCHAR(50),
    @IDUsuarioAccion INT,
    @Comentario      NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'PERSONAL';

    DECLARE @IDNuevo INT = (SELECT IDEstadoPedido FROM EstadosPedido WHERE NombreEstado = @NuevoEstado);
    IF @IDNuevo IS NULL
        THROW 50193, N'El estado indicado no existe.', 1;
    IF @NuevoEstado IN (N'Pendiente de pago', N'Pagado', N'Cancelado', N'Devuelto', N'Devuelto parcial')
        THROW 50191, N'Ese estado no se asigna por esta vía.', 1;

    DECLARE @IDActual INT, @NombreActual NVARCHAR(50), @Msg NVARCHAR(200), @Antes NVARCHAR(MAX), @Despues NVARCHAR(MAX);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @IDActual = p.IDEstadoPedido, @NombreActual = e.NombreEstado
        FROM Pedidos p WITH (UPDLOCK, HOLDLOCK)
        JOIN EstadosPedido e ON e.IDEstadoPedido = p.IDEstadoPedido
        WHERE p.IDPedido = @IDPedido;

        IF @IDActual IS NULL
            THROW 50184, N'El pedido no existe.', 1;

        IF NOT EXISTS (SELECT 1 FROM TransicionesEstadoPedido WHERE IDEstadoOrigen = @IDActual AND IDEstadoDestino = @IDNuevo)
        BEGIN
            SET @Msg = CONCAT(N'Transición no permitida: de "', @NombreActual, N'" a "', @NuevoEstado, N'".');
            THROW 50192, @Msg, 1;
        END;

        UPDATE Pedidos SET IDEstadoPedido = @IDNuevo WHERE IDPedido = @IDPedido;

        INSERT INTO HistorialEstadosPedido (IDPedido, IDEstadoAnterior, IDEstadoNuevo, IDUsuario, Comentario)
        VALUES (@IDPedido, @IDActual, @IDNuevo, @IDUsuarioAccion, @Comentario);

        SET @Antes = (SELECT @IDPedido AS IDPedido, @NombreActual AS Estado FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @Despues = (SELECT @IDPedido AS IDPedido, @NuevoEstado AS Estado FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Pedidos', 'Pedidos', @IDPedido, 'MODIFICAR', @Antes, @Despues;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @IDPedido AS IDPedido, @NuevoEstado AS Estado;
END;
GO

------------------------------------------------------------------
-- Cancelación: el cliente cancela los suyos; el personal cualquiera. Solo mientras no se despache.
-- Reintegra la existencia con movimientos de kardex. El cupón consumido no se restituye.
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Pedidos_Cancelar
    @IDPedido             INT,
    @IDUsuarioSolicitante INT,
    @Motivo               NVARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET LOCK_TIMEOUT 15000;

    IF @Motivo IS NULL OR LEN(LTRIM(RTRIM(@Motivo))) = 0
        THROW 50133, N'El motivo es obligatorio.', 1;

    DECLARE @Dueno INT = (SELECT IDUsuario FROM Pedidos WHERE IDPedido = @IDPedido);
    IF @Dueno IS NULL
        THROW 50184, N'El pedido no existe.', 1;

    DECLARE @EsPersonal BIT = CASE WHEN EXISTS (
        SELECT 1 FROM Usuarios u JOIN Roles r ON r.IDRol = u.IDRol
        WHERE u.IDUsuario = @IDUsuarioSolicitante AND u.Activo = 1
          AND r.NombreRol IN (N'Administrador', N'Operador')) THEN 1 ELSE 0 END;

    IF @EsPersonal = 0 AND @Dueno <> @IDUsuarioSolicitante
        THROW 50183, N'No tiene acceso a este pedido.', 1;

    DECLARE @IDCancelado INT = (SELECT IDEstadoPedido FROM EstadosPedido WHERE NombreEstado = N'Cancelado');
    DECLARE @IDActual INT, @NombreActual NVARCHAR(50), @Msg NVARCHAR(200), @Antes NVARCHAR(MAX), @Despues NVARCHAR(MAX);

    CREATE TABLE #Mov (IDVariante INT NOT NULL, Cantidad INT NOT NULL, ExistenciaResultante INT NOT NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @IDActual = p.IDEstadoPedido, @NombreActual = e.NombreEstado
        FROM Pedidos p WITH (UPDLOCK, HOLDLOCK)
        JOIN EstadosPedido e ON e.IDEstadoPedido = p.IDEstadoPedido
        WHERE p.IDPedido = @IDPedido;

        IF NOT EXISTS (SELECT 1 FROM TransicionesEstadoPedido WHERE IDEstadoOrigen = @IDActual AND IDEstadoDestino = @IDCancelado)
        BEGIN
            SET @Msg = CONCAT(N'No se puede cancelar un pedido en estado "', @NombreActual, N'".');
            THROW 50192, @Msg, 1;
        END;

        -- Reintegro de existencia
        UPDATE v
        SET v.ExistenciaFisica = v.ExistenciaFisica + pd.Cantidad
        OUTPUT inserted.IDVariante, pd.Cantidad, inserted.ExistenciaFisica
        INTO #Mov (IDVariante, Cantidad, ExistenciaResultante)
        FROM VariantesProducto v
        JOIN PedidoDetalle pd ON pd.IDVariante = v.IDVariante
        WHERE pd.IDPedido = @IDPedido;

        INSERT INTO MovimientosInventario (IDVariante, IDUsuario, TipoMovimiento, Cantidad, ExistenciaResultante, Motivo, IDPedido)
        SELECT IDVariante, @IDUsuarioSolicitante, 'DEVOLUCION', Cantidad, ExistenciaResultante,
               LEFT(CONCAT(N'Cancelación de pedido #', @IDPedido, N': ', LTRIM(RTRIM(@Motivo))), 255), @IDPedido
        FROM #Mov;

        UPDATE Pagos SET Estado = 'REEMBOLSADO' WHERE IDPedido = @IDPedido AND Estado = 'APROBADO';

        UPDATE Pedidos SET IDEstadoPedido = @IDCancelado WHERE IDPedido = @IDPedido;

        INSERT INTO HistorialEstadosPedido (IDPedido, IDEstadoAnterior, IDEstadoNuevo, IDUsuario, Comentario)
        VALUES (@IDPedido, @IDActual, @IDCancelado, @IDUsuarioSolicitante, LTRIM(RTRIM(@Motivo)));

        SET @Antes = (SELECT @IDPedido AS IDPedido, @NombreActual AS Estado FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @Despues = (SELECT @IDPedido AS IDPedido, N'Cancelado' AS Estado, LTRIM(RTRIM(@Motivo)) AS Motivo FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioSolicitante, 'Pedidos', 'Pedidos', @IDPedido, 'MODIFICAR', @Antes, @Despues;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @IDPedido AS IDPedido, N'Cancelado' AS Estado;
END;
GO

------------------------------------------------------------------
-- Devolución total o parcial por línea (las líneas llegan en un TVP).
-- Solo pedidos entregados. No se devuelve más de lo vendido en cada línea.
-- El reembolso se calcula de forma acumulada para que los centavos siempre cuadren.
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Pedidos_RegistrarDevolucion
    @IDPedido        INT,
    @Motivo          NVARCHAR(255),
    @Lineas          TT_Devoluciones_Lineas READONLY,
    @IDUsuarioAccion INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET LOCK_TIMEOUT 15000;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'PERSONAL';

    IF @Motivo IS NULL OR LEN(LTRIM(RTRIM(@Motivo))) = 0
        THROW 50133, N'El motivo es obligatorio.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Lineas)
        THROW 50204, N'Indique al menos una línea a devolver.', 1;

    DECLARE @IDActual INT, @NombreActual NVARCHAR(50), @IDDevolucion INT, @Monto DECIMAL(18,2),
            @Completo BIT, @Tipo VARCHAR(10), @NombreNuevo NVARCHAR(50), @IDNuevo INT, @Antes NVARCHAR(MAX), @Despues NVARCHAR(MAX);

    CREATE TABLE #Mov (IDVariante INT NOT NULL, Cantidad INT NOT NULL, ExistenciaResultante INT NOT NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @IDActual = p.IDEstadoPedido, @NombreActual = e.NombreEstado
        FROM Pedidos p WITH (UPDLOCK, HOLDLOCK)
        JOIN EstadosPedido e ON e.IDEstadoPedido = p.IDEstadoPedido
        WHERE p.IDPedido = @IDPedido;

        IF @IDActual IS NULL
            THROW 50184, N'El pedido no existe.', 1;
        IF @NombreActual NOT IN (N'Entregado', N'Devuelto parcial')
            THROW 50201, N'Solo se pueden registrar devoluciones de pedidos entregados.', 1;

        IF EXISTS (SELECT 1 FROM @Lineas l
                   WHERE NOT EXISTS (SELECT 1 FROM PedidoDetalle pd WHERE pd.IDPedidoDetalle = l.IDPedidoDetalle AND pd.IDPedido = @IDPedido))
            THROW 50202, N'Una de las líneas no pertenece al pedido.', 1;

        -- Bloquea las líneas y valida que no se devuelva más de lo vendido
        IF EXISTS (SELECT 1
                   FROM PedidoDetalle pd WITH (UPDLOCK, HOLDLOCK)
                   JOIN @Lineas l ON l.IDPedidoDetalle = pd.IDPedidoDetalle
                   WHERE pd.CantidadDevuelta + l.Cantidad > pd.Cantidad)
            THROW 50203, N'No se puede devolver más cantidad de la vendida en la línea.', 1;

        -- Reembolso acumulado: lo devuelto hasta ahora menos lo ya reembolsado antes
        SELECT @Monto = ISNULL(SUM(
                   ROUND(pd.TotalLinea * (pd.CantidadDevuelta + l.Cantidad) / pd.Cantidad, 2)
                 - ROUND(pd.TotalLinea * pd.CantidadDevuelta / pd.Cantidad, 2)), 0)
        FROM PedidoDetalle pd
        JOIN @Lineas l ON l.IDPedidoDetalle = pd.IDPedidoDetalle;

        UPDATE pd SET pd.CantidadDevuelta = pd.CantidadDevuelta + l.Cantidad
        FROM PedidoDetalle pd
        JOIN @Lineas l ON l.IDPedidoDetalle = pd.IDPedidoDetalle;

        SET @Completo = CASE WHEN EXISTS (SELECT 1 FROM PedidoDetalle WHERE IDPedido = @IDPedido AND CantidadDevuelta < Cantidad)
                             THEN 0 ELSE 1 END;
        SET @Tipo = CASE WHEN @Completo = 1 THEN 'TOTAL' ELSE 'PARCIAL' END;

        INSERT INTO Devoluciones (IDPedido, IDUsuario, Tipo, Motivo, MontoReembolso)
        VALUES (@IDPedido, @IDUsuarioAccion, @Tipo, LTRIM(RTRIM(@Motivo)), @Monto);
        SET @IDDevolucion = SCOPE_IDENTITY();

        INSERT INTO DevolucionDetalle (IDDevolucion, IDPedidoDetalle, Cantidad)
        SELECT @IDDevolucion, IDPedidoDetalle, Cantidad FROM @Lineas;

        -- Reintegro de existencia con su movimiento de kardex
        UPDATE v
        SET v.ExistenciaFisica = v.ExistenciaFisica + l.Cantidad
        OUTPUT inserted.IDVariante, l.Cantidad, inserted.ExistenciaFisica
        INTO #Mov (IDVariante, Cantidad, ExistenciaResultante)
        FROM VariantesProducto v
        JOIN PedidoDetalle pd ON pd.IDVariante = v.IDVariante
        JOIN @Lineas l ON l.IDPedidoDetalle = pd.IDPedidoDetalle;

        INSERT INTO MovimientosInventario (IDVariante, IDUsuario, TipoMovimiento, Cantidad, ExistenciaResultante, Motivo, IDPedido)
        SELECT IDVariante, @IDUsuarioAccion, 'DEVOLUCION', Cantidad, ExistenciaResultante,
               LEFT(CONCAT(N'Devolución de pedido #', @IDPedido, N': ', LTRIM(RTRIM(@Motivo))), 255), @IDPedido
        FROM #Mov;

        -- Estado del pedido (si no cambia, no se toca)
        SET @NombreNuevo = CASE WHEN @Completo = 1 THEN N'Devuelto' ELSE N'Devuelto parcial' END;
        SET @IDNuevo = (SELECT IDEstadoPedido FROM EstadosPedido WHERE NombreEstado = @NombreNuevo);

        IF @IDNuevo <> @IDActual
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM TransicionesEstadoPedido WHERE IDEstadoOrigen = @IDActual AND IDEstadoDestino = @IDNuevo)
                THROW 50192, N'Transición de estado no permitida para esta devolución.', 1;

            UPDATE Pedidos SET IDEstadoPedido = @IDNuevo WHERE IDPedido = @IDPedido;
            INSERT INTO HistorialEstadosPedido (IDPedido, IDEstadoAnterior, IDEstadoNuevo, IDUsuario, Comentario)
            VALUES (@IDPedido, @IDActual, @IDNuevo, @IDUsuarioAccion, LTRIM(RTRIM(@Motivo)));
        END;

        IF @Completo = 1
            UPDATE Pagos SET Estado = 'REEMBOLSADO' WHERE IDPedido = @IDPedido AND Estado = 'APROBADO';

        SET @Antes = (SELECT @IDPedido AS IDPedido, @NombreActual AS Estado FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @Despues = (SELECT @IDPedido AS IDPedido, @NombreNuevo AS Estado, @IDDevolucion AS IDDevolucion,
                               @Monto AS MontoReembolso, @Tipo AS Tipo FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Pedidos', 'Devoluciones', @IDDevolucion, 'CREAR', @Antes, @Despues;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @IDDevolucion AS IDDevolucion, @Tipo AS Tipo, @Monto AS MontoReembolso, @NombreNuevo AS EstadoPedido;
END;
GO

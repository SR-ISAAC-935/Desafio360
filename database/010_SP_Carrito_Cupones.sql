-- 010_SP_Carrito_Cupones.sql
-- Carrito de compras (usuario o invitado) y cupones.
-- Todo procedimiento del carrito recibe el dueño (IDUsuario o TokenInvitado) y valida que el
-- carrito le pertenezca: cambiar el identificador en la URL no expone datos de otro cliente.

------------------------------------------------------------------
-- Auxiliar: valida que el carrito exista, sea del solicitante y (opcional) esté activo
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Carrito_ValidarPropietario
    @IDCarrito     INT,
    @IDUsuario     INT = NULL,
    @TokenInvitado UNIQUEIDENTIFIER = NULL,
    @ExigirActivo  BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @DuenoUsuario INT, @DuenoToken UNIQUEIDENTIFIER, @Estado VARCHAR(15);

    SELECT @DuenoUsuario = IDUsuario, @DuenoToken = TokenInvitado, @Estado = Estado
    FROM Carritos
    WHERE IDCarrito = @IDCarrito;

    IF @Estado IS NULL
        THROW 50141, N'El carrito no existe.', 1;

    DECLARE @EsDueno BIT = CASE
        WHEN @IDUsuario IS NOT NULL AND @DuenoUsuario = @IDUsuario THEN 1
        WHEN @IDUsuario IS NULL AND @TokenInvitado IS NOT NULL AND @DuenoToken = @TokenInvitado THEN 1
        ELSE 0 END;

    IF @EsDueno = 0
        THROW 50142, N'No tiene acceso a este carrito.', 1;

    IF @ExigirActivo = 1 AND @Estado <> 'ACTIVO'
        THROW 50145, N'El carrito ya no está activo.', 1;
END;
GO

------------------------------------------------------------------
-- Obtener o crear el carrito activo
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Carrito_ObtenerOCrear
    @IDUsuario     INT = NULL,
    @TokenInvitado UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @IDCarrito INT;

    IF @IDUsuario IS NOT NULL
    BEGIN
        SELECT @IDCarrito = IDCarrito FROM Carritos WHERE IDUsuario = @IDUsuario AND Estado = 'ACTIVO';
    END
    ELSE IF @TokenInvitado IS NOT NULL
    BEGIN
        SELECT @IDCarrito = IDCarrito FROM Carritos WHERE TokenInvitado = @TokenInvitado AND Estado = 'ACTIVO';
    END

    IF @IDCarrito IS NULL
    BEGIN
        BEGIN TRY
            IF @IDUsuario IS NOT NULL
            BEGIN
                INSERT INTO Carritos (IDUsuario) VALUES (@IDUsuario);
            END
            ELSE
            BEGIN
                INSERT INTO Carritos (TokenInvitado) VALUES (NEWID());
            END
            SET @IDCarrito = SCOPE_IDENTITY();
        END TRY
        BEGIN CATCH
            -- Dos solicitudes simultáneas: la otra ya creó el carrito activo
            IF ERROR_NUMBER() IN (2601, 2627) AND @IDUsuario IS NOT NULL
            BEGIN
                SELECT @IDCarrito = IDCarrito FROM Carritos WHERE IDUsuario = @IDUsuario AND Estado = 'ACTIVO';
            END
            ELSE
            BEGIN
                THROW;
            END
        END CATCH;
    END;

    SELECT IDCarrito, IDUsuario, TokenInvitado, Estado, FechaUltimaActividad
    FROM Carritos
    WHERE IDCarrito = @IDCarrito;
END;
GO

------------------------------------------------------------------
-- Resumen del carrito: encabezado, líneas y totales (subtotal, descuento, total, IVA incluido)
-- Los precios incluyen IVA del 12 %. Cada importe se calcula con DECIMAL(18,2):
-- no hay redondeos acumulados (cantidad x precio es exacto y el descuento se redondea una vez).
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Carrito_Resumen
    @IDCarrito     INT,
    @IDUsuario     INT = NULL,
    @TokenInvitado UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    EXEC SP_Carrito_ValidarPropietario @IDCarrito, @IDUsuario, @TokenInvitado, 0;

    DECLARE @IDCupon INT, @Subtotal DECIMAL(18,2), @Descuento DECIMAL(18,2) = 0, @CuponValido BIT = 0;

    SELECT @IDCupon = IDCupon FROM Carritos WHERE IDCarrito = @IDCarrito;

    SELECT @Subtotal = CAST(ISNULL(SUM(cd.Cantidad * v.Precio), 0) AS DECIMAL(18,2))
    FROM CarritoDetalle cd
    JOIN VariantesProducto v ON v.IDVariante = cd.IDVariante
    WHERE cd.IDCarrito = @IDCarrito;

    IF @IDCupon IS NOT NULL
    BEGIN
        SELECT @Descuento = f.Descuento, @CuponValido = 1
        FROM Cupones c
        CROSS APPLY FU_Cupones_CalculoDescuento(c.IDCupon, @IDCarrito) f
        WHERE c.IDCupon = @IDCupon
          AND c.Activo = 1
          AND SYSUTCDATETIME() BETWEEN c.FechaInicio AND c.FechaFin
          AND c.UsosActuales < c.LimiteUsosTotal
          AND @Subtotal >= c.MontoMinimo
          AND f.BaseAplicable > 0;
    END;

    -- 1) Encabezado
    SELECT c.IDCarrito, c.Estado, c.IDCupon, cu.Codigo AS CodigoCupon, @CuponValido AS CuponValido
    FROM Carritos c
    LEFT JOIN Cupones cu ON cu.IDCupon = c.IDCupon
    WHERE c.IDCarrito = @IDCarrito;

    -- 2) Líneas
    SELECT cd.IDVariante, v.SKU, p.NombreProducto, v.Talla, v.Color, v.ImagenUrl,
           cd.Cantidad, v.Precio AS PrecioUnitario,
           CAST(cd.Cantidad * v.Precio AS DECIMAL(18,2)) AS TotalLinea,
           CASE WHEN d.Disponible > 0 THEN d.Disponible ELSE 0 END AS Disponible,
           CASE WHEN cd.Cantidad > d.Disponible OR v.Activo = 0 OR p.Activo = 0 THEN 1 ELSE 0 END AS SinExistencia
    FROM CarritoDetalle cd
    JOIN VariantesProducto v ON v.IDVariante = cd.IDVariante
    JOIN Productos p ON p.IDProducto = v.IDProducto
    JOIN FU_Inventario_Disponibilidad(@IDCarrito) d ON d.IDVariante = cd.IDVariante
    WHERE cd.IDCarrito = @IDCarrito
    ORDER BY p.NombreProducto, v.SKU;

    -- 3) Totales
    SELECT @Subtotal AS Subtotal,
           @Descuento AS Descuento,
           @Subtotal - @Descuento AS Total,
           CAST(ROUND((@Subtotal - @Descuento) * 12 / 112, 2) AS DECIMAL(18,2)) AS IVAIncluido;
END;
GO

------------------------------------------------------------------
-- Agregar / modificar / eliminar productos
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Carrito_AgregarProducto
    @IDCarrito     INT,
    @IDVariante    INT,
    @Cantidad      INT,
    @IDUsuario     INT = NULL,
    @TokenInvitado UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET LOCK_TIMEOUT 15000;

    IF @Cantidad IS NULL OR @Cantidad <= 0 OR @Cantidad > 1000
        THROW 50147, N'La cantidad debe estar entre 1 y 1000.', 1;

    EXEC SP_Carrito_ValidarPropietario @IDCarrito, @IDUsuario, @TokenInvitado, 1;

    DECLARE @Disponible INT, @Actual INT, @Msg NVARCHAR(200), @Valida BIT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Bloquea la variante mientras se valida la existencia
        SELECT @Valida = CASE WHEN v.Activo = 1 AND p.Activo = 1 AND c.Activo = 1 THEN 1 ELSE 0 END
        FROM VariantesProducto v WITH (UPDLOCK, HOLDLOCK)
        JOIN Productos p ON p.IDProducto = v.IDProducto
        JOIN Categorias c ON c.IDCategoria = p.IDCategoria
        WHERE v.IDVariante = @IDVariante;

        IF @Valida IS NULL OR @Valida = 0
            THROW 50143, N'El producto no está disponible.', 1;

        SET @Actual = ISNULL((SELECT Cantidad FROM CarritoDetalle
                              WHERE IDCarrito = @IDCarrito AND IDVariante = @IDVariante), 0);
        IF @Actual + @Cantidad > 1000
            THROW 50147, N'La cantidad máxima por producto en el carrito es 1000.', 1;

        SELECT @Disponible = Disponible FROM FU_Inventario_Disponibilidad(@IDCarrito) WHERE IDVariante = @IDVariante;

        IF @Actual + @Cantidad > @Disponible
        BEGIN
            SET @Msg = CONCAT(N'Solo hay ', CASE WHEN @Disponible < 0 THEN 0 ELSE @Disponible END,
                              N' unidades disponibles de este producto.');
            THROW 50144, @Msg, 1;
        END;

        UPDATE CarritoDetalle SET Cantidad = Cantidad + @Cantidad
        WHERE IDCarrito = @IDCarrito AND IDVariante = @IDVariante;
        IF @@ROWCOUNT = 0
            INSERT INTO CarritoDetalle (IDCarrito, IDVariante, Cantidad) VALUES (@IDCarrito, @IDVariante, @Cantidad);

        UPDATE Carritos SET FechaUltimaActividad = SYSUTCDATETIME() WHERE IDCarrito = @IDCarrito;
        -- Si el carrito cambia, la reserva anterior ya no corresponde
        UPDATE ReservasExistencia SET Estado = 'LIBERADA' WHERE IDCarrito = @IDCarrito AND Estado = 'ACTIVA';

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    EXEC SP_Carrito_Resumen @IDCarrito, @IDUsuario, @TokenInvitado;
END;
GO

-- Fija la cantidad de una línea (debe ser mayor a cero; para quitarla use SP_Carrito_EliminarProducto)
CREATE OR ALTER PROCEDURE SP_Carrito_ActualizarCantidad
    @IDCarrito     INT,
    @IDVariante    INT,
    @Cantidad      INT,
    @IDUsuario     INT = NULL,
    @TokenInvitado UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET LOCK_TIMEOUT 15000;

    IF @Cantidad IS NULL OR @Cantidad <= 0 OR @Cantidad > 1000
        THROW 50147, N'La cantidad debe estar entre 1 y 1000.', 1;

    EXEC SP_Carrito_ValidarPropietario @IDCarrito, @IDUsuario, @TokenInvitado, 1;

    DECLARE @Disponible INT, @Msg NVARCHAR(200), @Valida BIT;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS (SELECT 1 FROM CarritoDetalle WHERE IDCarrito = @IDCarrito AND IDVariante = @IDVariante)
            THROW 50146, N'El producto no está en el carrito.', 1;

        SELECT @Valida = CASE WHEN v.Activo = 1 AND p.Activo = 1 AND c.Activo = 1 THEN 1 ELSE 0 END
        FROM VariantesProducto v WITH (UPDLOCK, HOLDLOCK)
        JOIN Productos p ON p.IDProducto = v.IDProducto
        JOIN Categorias c ON c.IDCategoria = p.IDCategoria
        WHERE v.IDVariante = @IDVariante;

        IF @Valida IS NULL OR @Valida = 0
            THROW 50143, N'El producto no está disponible.', 1;

        SELECT @Disponible = Disponible FROM FU_Inventario_Disponibilidad(@IDCarrito) WHERE IDVariante = @IDVariante;

        IF @Cantidad > @Disponible
        BEGIN
            SET @Msg = CONCAT(N'Solo hay ', CASE WHEN @Disponible < 0 THEN 0 ELSE @Disponible END,
                              N' unidades disponibles de este producto.');
            THROW 50144, @Msg, 1;
        END;

        UPDATE CarritoDetalle SET Cantidad = @Cantidad WHERE IDCarrito = @IDCarrito AND IDVariante = @IDVariante;
        UPDATE Carritos SET FechaUltimaActividad = SYSUTCDATETIME() WHERE IDCarrito = @IDCarrito;
        UPDATE ReservasExistencia SET Estado = 'LIBERADA' WHERE IDCarrito = @IDCarrito AND Estado = 'ACTIVA';

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    EXEC SP_Carrito_Resumen @IDCarrito, @IDUsuario, @TokenInvitado;
END;
GO

CREATE OR ALTER PROCEDURE SP_Carrito_EliminarProducto
    @IDCarrito     INT,
    @IDVariante    INT,
    @IDUsuario     INT = NULL,
    @TokenInvitado UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    EXEC SP_Carrito_ValidarPropietario @IDCarrito, @IDUsuario, @TokenInvitado, 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM CarritoDetalle WHERE IDCarrito = @IDCarrito AND IDVariante = @IDVariante;
        IF @@ROWCOUNT = 0
            THROW 50146, N'El producto no está en el carrito.', 1;

        UPDATE Carritos SET FechaUltimaActividad = SYSUTCDATETIME() WHERE IDCarrito = @IDCarrito;
        UPDATE ReservasExistencia SET Estado = 'LIBERADA' WHERE IDCarrito = @IDCarrito AND Estado = 'ACTIVA';

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    EXEC SP_Carrito_Resumen @IDCarrito, @IDUsuario, @TokenInvitado;
END;
GO

-- Al iniciar sesión: el carrito de invitado pasa al usuario o se fusiona con el que ya tenga.
-- Las cantidades fusionadas se limitan a la existencia disponible.
CREATE OR ALTER PROCEDURE SP_Carrito_Fusionar
    @TokenInvitado UNIQUEIDENTIFIER,
    @IDUsuario     INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @IDInvitado INT, @IDUsuarioCarrito INT;

    SELECT @IDInvitado = IDCarrito FROM Carritos WHERE TokenInvitado = @TokenInvitado AND Estado = 'ACTIVO';

    IF @IDInvitado IS NOT NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            SELECT @IDUsuarioCarrito = IDCarrito FROM Carritos WITH (UPDLOCK, HOLDLOCK)
            WHERE IDUsuario = @IDUsuario AND Estado = 'ACTIVO';

            IF @IDUsuarioCarrito IS NULL
            BEGIN
                -- El usuario no tenía carrito: el de invitado pasa a ser suyo
                UPDATE Carritos SET IDUsuario = @IDUsuario, TokenInvitado = NULL WHERE IDCarrito = @IDInvitado;
            END
            ELSE
            BEGIN
                SELECT g.IDVariante,
                       CASE WHEN x.Deseada > 1000 THEN 1000 ELSE x.Deseada END AS CantidadFinal,
                       CASE WHEN u.IDCarritoDetalle IS NULL THEN 0 ELSE 1 END AS ExisteEnUsuario
                INTO #Fusion
                FROM CarritoDetalle g
                JOIN VariantesProducto v ON v.IDVariante = g.IDVariante AND v.Activo = 1
                JOIN Productos p ON p.IDProducto = v.IDProducto AND p.Activo = 1
                JOIN FU_Inventario_Disponibilidad(NULL) d ON d.IDVariante = g.IDVariante
                LEFT JOIN CarritoDetalle u ON u.IDCarrito = @IDUsuarioCarrito AND u.IDVariante = g.IDVariante
                CROSS APPLY (SELECT CASE WHEN ISNULL(u.Cantidad, 0) + g.Cantidad < d.Disponible
                                         THEN ISNULL(u.Cantidad, 0) + g.Cantidad ELSE d.Disponible END AS Deseada) x
                WHERE g.IDCarrito = @IDInvitado;

                UPDATE u SET u.Cantidad = f.CantidadFinal
                FROM CarritoDetalle u
                JOIN #Fusion f ON f.IDVariante = u.IDVariante
                WHERE u.IDCarrito = @IDUsuarioCarrito AND f.ExisteEnUsuario = 1 AND f.CantidadFinal > 0;

                INSERT INTO CarritoDetalle (IDCarrito, IDVariante, Cantidad)
                SELECT @IDUsuarioCarrito, f.IDVariante, f.CantidadFinal
                FROM #Fusion f
                WHERE f.ExisteEnUsuario = 0 AND f.CantidadFinal > 0;

                UPDATE Carritos SET Estado = 'ABANDONADO' WHERE IDCarrito = @IDInvitado;
                UPDATE Carritos SET FechaUltimaActividad = SYSUTCDATETIME() WHERE IDCarrito = @IDUsuarioCarrito;
                UPDATE ReservasExistencia SET Estado = 'LIBERADA'
                WHERE IDCarrito IN (@IDInvitado, @IDUsuarioCarrito) AND Estado = 'ACTIVA';
            END;

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            THROW;
        END CATCH;
    END;

    -- Devuelve el carrito activo del usuario
    EXEC SP_Carrito_ObtenerOCrear @IDUsuario = @IDUsuario;
END;
GO

------------------------------------------------------------------
-- Cupones: validación (mensajes específicos) y aplicación al carrito
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Cupones_Validar
    @IDCarrito INT,
    @IDUsuario INT,
    @Codigo    VARCHAR(50),
    @IDCupon   INT OUTPUT,
    @Descuento DECIMAL(18,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Activo BIT, @Inicio DATETIME2(0), @Fin DATETIME2(0), @Minimo DECIMAL(18,2),
            @LimiteTotal INT, @Usos INT, @LimiteCliente INT,
            @Subtotal DECIMAL(18,2), @UsosCliente INT, @Base DECIMAL(18,2), @Msg NVARCHAR(200);

    SELECT @IDCupon = IDCupon, @Activo = Activo, @Inicio = FechaInicio, @Fin = FechaFin, @Minimo = MontoMinimo,
           @LimiteTotal = LimiteUsosTotal, @Usos = UsosActuales, @LimiteCliente = LimiteUsosPorCliente
    FROM Cupones
    WHERE Codigo = LTRIM(RTRIM(@Codigo));

    IF @IDCupon IS NULL
        THROW 50151, N'El cupón no existe.', 1;
    IF @Activo = 0
        THROW 50152, N'El cupón no está activo.', 1;
    IF SYSUTCDATETIME() < @Inicio
        THROW 50153, N'El cupón todavía no está vigente.', 1;
    IF SYSUTCDATETIME() > @Fin
        THROW 50154, N'El cupón está vencido.', 1;
    IF @Usos >= @LimiteTotal
        THROW 50155, N'El cupón está agotado.', 1;

    SELECT @Subtotal = CAST(ISNULL(SUM(cd.Cantidad * v.Precio), 0) AS DECIMAL(18,2))
    FROM CarritoDetalle cd
    JOIN VariantesProducto v ON v.IDVariante = cd.IDVariante
    WHERE cd.IDCarrito = @IDCarrito;

    IF @Subtotal < @Minimo
    BEGIN
        SET @Msg = CONCAT(N'La compra no alcanza el monto mínimo de Q', CAST(@Minimo AS NVARCHAR(30)), N' para este cupón.');
        THROW 50156, @Msg, 1;
    END;

    SELECT @UsosCliente = COUNT(*) FROM UsosCupon WHERE IDCupon = @IDCupon AND IDUsuario = @IDUsuario;
    IF @UsosCliente >= @LimiteCliente
        THROW 50157, N'Ya usó este cupón el máximo de veces permitido.', 1;

    SELECT @Base = BaseAplicable, @Descuento = Descuento FROM FU_Cupones_CalculoDescuento(@IDCupon, @IDCarrito);
    IF @Base <= 0
        THROW 50158, N'El carrito no contiene productos de la categoría del cupón.', 1;
END;
GO

-- Solo se permite un cupón por pedido: aplicar otro reemplaza al anterior.
CREATE OR ALTER PROCEDURE SP_Carrito_AplicarCupon
    @IDCarrito INT,
    @IDUsuario INT = NULL,
    @Codigo    VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    IF @IDUsuario IS NULL
        THROW 50159, N'Inicie sesión para aplicar un cupón.', 1;

    EXEC SP_Carrito_ValidarPropietario @IDCarrito, @IDUsuario, NULL, 1;

    DECLARE @IDCupon INT, @Descuento DECIMAL(18,2);
    EXEC SP_Cupones_Validar @IDCarrito, @IDUsuario, @Codigo, @IDCupon OUTPUT, @Descuento OUTPUT;

    UPDATE Carritos SET IDCupon = @IDCupon, FechaUltimaActividad = SYSUTCDATETIME() WHERE IDCarrito = @IDCarrito;

    EXEC SP_Carrito_Resumen @IDCarrito, @IDUsuario, NULL;
END;
GO

CREATE OR ALTER PROCEDURE SP_Carrito_QuitarCupon
    @IDCarrito     INT,
    @IDUsuario     INT = NULL,
    @TokenInvitado UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC SP_Carrito_ValidarPropietario @IDCarrito, @IDUsuario, @TokenInvitado, 1;
    UPDATE Carritos SET IDCupon = NULL, FechaUltimaActividad = SYSUTCDATETIME() WHERE IDCarrito = @IDCarrito;
    EXEC SP_Carrito_Resumen @IDCarrito, @IDUsuario, @TokenInvitado;
END;
GO

------------------------------------------------------------------
-- CRUD de cupones (Administrador)
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Cupones_Crear
    @Codigo               VARCHAR(50),
    @Descripcion          NVARCHAR(255) = NULL,
    @Tipo                 VARCHAR(15),
    @Valor                DECIMAL(18,2),
    @FechaInicio          DATETIME2(0),
    @FechaFin             DATETIME2(0),
    @MontoMinimo          DECIMAL(18,2) = 0,
    @LimiteUsosTotal      INT,
    @LimiteUsosPorCliente INT = 1,
    @IDCategoria          INT = NULL,
    @IDUsuarioAccion      INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    DECLARE @IDCupon INT, @Json NVARCHAR(MAX);

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO Cupones (Codigo, Descripcion, Tipo, Valor, FechaInicio, FechaFin, MontoMinimo,
                             LimiteUsosTotal, LimiteUsosPorCliente, IDCategoria)
        VALUES (UPPER(LTRIM(RTRIM(@Codigo))), @Descripcion, @Tipo, @Valor, @FechaInicio, @FechaFin, @MontoMinimo,
                @LimiteUsosTotal, @LimiteUsosPorCliente, @IDCategoria);
        SET @IDCupon = SCOPE_IDENTITY();

        SET @Json = (SELECT * FROM Cupones WHERE IDCupon = @IDCupon FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Cupones', 'Cupones', @IDCupon, 'CREAR', NULL, @Json;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() IN (2601, 2627) THROW 50161, N'Ya existe un cupón con ese código.', 1;
        IF ERROR_NUMBER() = 547 THROW 50162, N'Los datos del cupón no cumplen las reglas de validación.', 1;
        THROW;
    END CATCH;

    SELECT @IDCupon AS IDCupon;
END;
GO

CREATE OR ALTER PROCEDURE SP_Cupones_Actualizar
    @IDCupon              INT,
    @Descripcion          NVARCHAR(255) = NULL,
    @Tipo                 VARCHAR(15),
    @Valor                DECIMAL(18,2),
    @FechaInicio          DATETIME2(0),
    @FechaFin             DATETIME2(0),
    @MontoMinimo          DECIMAL(18,2),
    @LimiteUsosTotal      INT,
    @LimiteUsosPorCliente INT,
    @IDCategoria          INT = NULL,
    @Activo               BIT,
    @IDUsuarioAccion      INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    DECLARE @Antes NVARCHAR(MAX), @Despues NVARCHAR(MAX);
    DECLARE @Accion VARCHAR(15) = CASE WHEN @Activo = 0 THEN 'DESACTIVAR' ELSE 'MODIFICAR' END;

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @Antes = (SELECT * FROM Cupones WITH (UPDLOCK) WHERE IDCupon = @IDCupon FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        IF @Antes IS NULL
            THROW 50163, N'El cupón no existe.', 1;

        UPDATE Cupones
        SET Descripcion = @Descripcion, Tipo = @Tipo, Valor = @Valor, FechaInicio = @FechaInicio, FechaFin = @FechaFin,
            MontoMinimo = @MontoMinimo, LimiteUsosTotal = @LimiteUsosTotal,
            LimiteUsosPorCliente = @LimiteUsosPorCliente, IDCategoria = @IDCategoria, Activo = @Activo
        WHERE IDCupon = @IDCupon;

        SET @Despues = (SELECT * FROM Cupones WHERE IDCupon = @IDCupon FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Cupones', 'Cupones', @IDCupon,
             @Accion, @Antes, @Despues;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() = 547 THROW 50162, N'Los datos del cupón no cumplen las reglas de validación.', 1;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE SP_Cupones_Listar
    @IDUsuarioAccion INT,
    @Buscar          NVARCHAR(50) = NULL,
    @Activo          BIT = NULL,
    @Pagina          INT = 1,
    @TamanoPagina    INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    SET @Pagina = CASE WHEN @Pagina IS NULL OR @Pagina < 1 THEN 1 ELSE @Pagina END;
    SET @TamanoPagina = CASE WHEN @TamanoPagina IS NULL OR @TamanoPagina < 1 THEN 20
                             WHEN @TamanoPagina > 100 THEN 100 ELSE @TamanoPagina END;

    DECLARE @Patron NVARCHAR(120) = NULL;
    IF @Buscar IS NOT NULL AND LEN(LTRIM(RTRIM(@Buscar))) > 0
        SET @Patron = N'%' + REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Buscar)),
                      N'\', N'\\'), N'%', N'\%'), N'_', N'\_'), N'[', N'\[') + N'%';

    SELECT c.IDCupon, c.Codigo, c.Descripcion, c.Tipo, c.Valor, c.FechaInicio, c.FechaFin, c.MontoMinimo,
           c.LimiteUsosTotal, c.UsosActuales, c.LimiteUsosPorCliente, c.IDCategoria, cat.NombreCategoria, c.Activo,
           COUNT(*) OVER() AS TotalRegistros
    FROM Cupones c
    LEFT JOIN Categorias cat ON cat.IDCategoria = c.IDCategoria
    WHERE (@Patron IS NULL OR c.Codigo LIKE @Patron ESCAPE N'\' OR c.Descripcion LIKE @Patron ESCAPE N'\')
      AND (@Activo IS NULL OR c.Activo = @Activo)
    ORDER BY c.FechaFin DESC, c.IDCupon DESC
    OFFSET (@Pagina - 1) * @TamanoPagina ROWS FETCH NEXT @TamanoPagina ROWS ONLY;
END;
GO

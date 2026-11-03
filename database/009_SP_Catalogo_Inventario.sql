-- 009_SP_Catalogo_Inventario.sql
-- Catálogo (categorías, productos, variantes) e inventario (kardex, ajustes, reservas vencidas).
-- Las escrituras de catálogo son de Administrador; las de inventario, de Operador o Administrador.

------------------------------------------------------------------
-- Categorías
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Categorias_Crear
    @NombreCategoria NVARCHAR(100),
    @Descripcion     NVARCHAR(500) = NULL,
    @IDUsuarioAccion INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    DECLARE @IDCategoria INT, @Json NVARCHAR(MAX);

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO Categorias (NombreCategoria, Descripcion)
        VALUES (LTRIM(RTRIM(@NombreCategoria)), @Descripcion);
        SET @IDCategoria = SCOPE_IDENTITY();

        SET @Json = (SELECT * FROM Categorias WHERE IDCategoria = @IDCategoria FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Productos', 'Categorias', @IDCategoria, 'CREAR', NULL, @Json;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() IN (2601, 2627) THROW 50121, N'Ya existe una categoría con ese nombre.', 1;
        THROW;
    END CATCH;

    SELECT @IDCategoria AS IDCategoria;
END;
GO

CREATE OR ALTER PROCEDURE SP_Categorias_Actualizar
    @IDCategoria     INT,
    @NombreCategoria NVARCHAR(100),
    @Descripcion     NVARCHAR(500) = NULL,
    @Activo          BIT,
    @IDUsuarioAccion INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    DECLARE @Antes NVARCHAR(MAX), @Despues NVARCHAR(MAX);
    DECLARE @Accion VARCHAR(15) = CASE WHEN @Activo = 0 THEN 'DESACTIVAR' ELSE 'MODIFICAR' END;

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @Antes = (SELECT * FROM Categorias WHERE IDCategoria = @IDCategoria FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        IF @Antes IS NULL
            THROW 50122, N'La categoría no existe.', 1;

        UPDATE Categorias
        SET NombreCategoria = LTRIM(RTRIM(@NombreCategoria)), Descripcion = @Descripcion, Activo = @Activo
        WHERE IDCategoria = @IDCategoria;

        SET @Despues = (SELECT * FROM Categorias WHERE IDCategoria = @IDCategoria FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Productos', 'Categorias', @IDCategoria,
             @Accion, @Antes, @Despues;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() IN (2601, 2627) THROW 50121, N'Ya existe una categoría con ese nombre.', 1;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE SP_Categorias_Listar
    @SoloActivas BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SELECT IDCategoria, NombreCategoria, Descripcion, Activo
    FROM Categorias
    WHERE (@SoloActivas = 0 OR Activo = 1)
    ORDER BY NombreCategoria;
END;
GO

------------------------------------------------------------------
-- Productos y variantes (las variantes llegan en un TVP)
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Productos_Crear
    @NombreProducto  NVARCHAR(150),
    @IDCategoria     INT,
    @Descripcion     NVARCHAR(1000) = NULL,
    @Variantes       TT_Catalogo_Variantes READONLY,
    @IDUsuarioAccion INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    IF NOT EXISTS (SELECT 1 FROM @Variantes)
        THROW 50125, N'El producto debe tener al menos una variante.', 1;
    IF NOT EXISTS (SELECT 1 FROM Categorias WHERE IDCategoria = @IDCategoria AND Activo = 1)
        THROW 50122, N'La categoría no existe o está inactiva.', 1;

    DECLARE @IDProducto INT, @Json NVARCHAR(MAX);

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO Productos (NombreProducto, IDCategoria, Descripcion)
        VALUES (LTRIM(RTRIM(@NombreProducto)), @IDCategoria, @Descripcion);
        SET @IDProducto = SCOPE_IDENTITY();

        INSERT INTO VariantesProducto (IDProducto, SKU, Talla, Color, Precio, ExistenciaFisica, ImagenUrl)
        SELECT @IDProducto, SKU, Talla, Color, Precio, ExistenciaInicial, ImagenUrl
        FROM @Variantes;

        -- La existencia inicial queda en el kardex
        INSERT INTO MovimientosInventario (IDVariante, IDUsuario, TipoMovimiento, Cantidad, ExistenciaResultante, Motivo)
        SELECT v.IDVariante, @IDUsuarioAccion, 'ENTRADA', t.ExistenciaInicial, t.ExistenciaInicial, N'Inventario inicial'
        FROM @Variantes t
        JOIN VariantesProducto v ON v.SKU = t.SKU
        WHERE t.ExistenciaInicial > 0;

        SET @Json = (SELECT p.IDProducto, p.NombreProducto, p.IDCategoria,
                            (SELECT SKU, Talla, Color, Precio, ExistenciaFisica
                             FROM VariantesProducto WHERE IDProducto = p.IDProducto FOR JSON PATH) AS Variantes
                     FROM Productos p WHERE p.IDProducto = @IDProducto
                     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Productos', 'Productos', @IDProducto, 'CREAR', NULL, @Json;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() IN (2601, 2627) THROW 50121, N'Ya existe un producto con ese nombre o un SKU repetido.', 1;
        IF ERROR_NUMBER() = 547 THROW 50126, N'Los datos del producto no cumplen las reglas de validación.', 1;
        THROW;
    END CATCH;

    SELECT @IDProducto AS IDProducto;
END;
GO

-- Desactivar un producto lo oculta de la tienda y conserva su historial de ventas.
CREATE OR ALTER PROCEDURE SP_Productos_Actualizar
    @IDProducto      INT,
    @NombreProducto  NVARCHAR(150),
    @IDCategoria     INT,
    @Descripcion     NVARCHAR(1000) = NULL,
    @Activo          BIT,
    @IDUsuarioAccion INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    IF NOT EXISTS (SELECT 1 FROM Categorias WHERE IDCategoria = @IDCategoria)
        THROW 50122, N'La categoría no existe.', 1;

    DECLARE @Antes NVARCHAR(MAX), @Despues NVARCHAR(MAX);
    DECLARE @Accion VARCHAR(15) = CASE WHEN @Activo = 0 THEN 'DESACTIVAR' ELSE 'MODIFICAR' END;

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @Antes = (SELECT * FROM Productos WHERE IDProducto = @IDProducto FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        IF @Antes IS NULL
            THROW 50123, N'El producto no existe.', 1;

        UPDATE Productos
        SET NombreProducto = LTRIM(RTRIM(@NombreProducto)), IDCategoria = @IDCategoria,
            Descripcion = @Descripcion, Activo = @Activo
        WHERE IDProducto = @IDProducto;

        SET @Despues = (SELECT * FROM Productos WHERE IDProducto = @IDProducto FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Productos', 'Productos', @IDProducto,
             @Accion, @Antes, @Despues;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() IN (2601, 2627) THROW 50121, N'Ya existe un producto con ese nombre.', 1;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE SP_Variantes_Crear
    @IDProducto        INT,
    @SKU               VARCHAR(50),
    @Talla             NVARCHAR(30) = NULL,
    @Color             NVARCHAR(30) = NULL,
    @Precio            DECIMAL(18,2),
    @ExistenciaInicial INT = 0,
    @ImagenUrl         NVARCHAR(255) = NULL,
    @IDUsuarioAccion   INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    IF NOT EXISTS (SELECT 1 FROM Productos WHERE IDProducto = @IDProducto)
        THROW 50123, N'El producto no existe.', 1;

    DECLARE @IDVariante INT, @Json NVARCHAR(MAX);

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO VariantesProducto (IDProducto, SKU, Talla, Color, Precio, ExistenciaFisica, ImagenUrl)
        VALUES (@IDProducto, @SKU, @Talla, @Color, @Precio, @ExistenciaInicial, @ImagenUrl);
        SET @IDVariante = SCOPE_IDENTITY();

        IF @ExistenciaInicial > 0
            INSERT INTO MovimientosInventario (IDVariante, IDUsuario, TipoMovimiento, Cantidad, ExistenciaResultante, Motivo)
            VALUES (@IDVariante, @IDUsuarioAccion, 'ENTRADA', @ExistenciaInicial, @ExistenciaInicial, N'Inventario inicial');

        SET @Json = (SELECT IDVariante, IDProducto, SKU, Talla, Color, Precio, ExistenciaFisica
                     FROM VariantesProducto WHERE IDVariante = @IDVariante FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Productos', 'VariantesProducto', @IDVariante, 'CREAR', NULL, @Json;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() IN (2601, 2627) THROW 50121, N'Ya existe una variante con ese SKU.', 1;
        IF ERROR_NUMBER() = 547 THROW 50126, N'Los datos de la variante no cumplen las reglas de validación.', 1;
        THROW;
    END CATCH;

    SELECT @IDVariante AS IDVariante;
END;
GO

-- No modifica precio ni existencia (tienen sus propios procedimientos con trazabilidad).
CREATE OR ALTER PROCEDURE SP_Variantes_Actualizar
    @IDVariante      INT,
    @Talla           NVARCHAR(30) = NULL,
    @Color           NVARCHAR(30) = NULL,
    @ImagenUrl       NVARCHAR(255) = NULL,
    @Activo          BIT,
    @IDUsuarioAccion INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    DECLARE @Antes NVARCHAR(MAX), @Despues NVARCHAR(MAX);
    DECLARE @Accion VARCHAR(15) = CASE WHEN @Activo = 0 THEN 'DESACTIVAR' ELSE 'MODIFICAR' END;

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @Antes = (SELECT IDVariante, SKU, Talla, Color, ImagenUrl, Activo FROM VariantesProducto
                      WHERE IDVariante = @IDVariante FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        IF @Antes IS NULL
            THROW 50124, N'La variante no existe.', 1;

        UPDATE VariantesProducto
        SET Talla = @Talla, Color = @Color, ImagenUrl = @ImagenUrl, Activo = @Activo
        WHERE IDVariante = @IDVariante;

        SET @Despues = (SELECT IDVariante, SKU, Talla, Color, ImagenUrl, Activo FROM VariantesProducto
                        WHERE IDVariante = @IDVariante FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Productos', 'VariantesProducto', @IDVariante,
             @Accion, @Antes, @Despues;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

-- Un cambio de precio no afecta pedidos ya realizados (PedidoDetalle congela el precio).
CREATE OR ALTER PROCEDURE SP_Variantes_CambiarPrecio
    @IDVariante      INT,
    @PrecioNuevo     DECIMAL(18,2),
    @IDUsuarioAccion INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    IF @PrecioNuevo IS NULL OR @PrecioNuevo < 0 OR @PrecioNuevo > 9999999.99
        THROW 50126, N'El precio debe estar entre 0 y 9,999,999.99.', 1;

    DECLARE @PrecioAnterior DECIMAL(18,2), @Antes NVARCHAR(MAX), @Despues NVARCHAR(MAX);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @PrecioAnterior = Precio FROM VariantesProducto WITH (UPDLOCK) WHERE IDVariante = @IDVariante;
        IF @PrecioAnterior IS NULL
            THROW 50124, N'La variante no existe.', 1;

        UPDATE VariantesProducto SET Precio = @PrecioNuevo WHERE IDVariante = @IDVariante;

        SET @Antes = (SELECT @IDVariante AS IDVariante, @PrecioAnterior AS Precio FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @Despues = (SELECT @IDVariante AS IDVariante, @PrecioNuevo AS Precio FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Precios', 'VariantesProducto', @IDVariante, 'MODIFICAR', @Antes, @Despues;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

------------------------------------------------------------------
-- Consulta del catálogo (tienda): búsqueda, filtros, orden y paginación en el servidor
-- @Ordenar: NOMBRE_ASC | NOMBRE_DESC | PRECIO_ASC | PRECIO_DESC
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Catalogo_Buscar
    @Texto           NVARCHAR(100) = NULL,
    @IDCategoria     INT = NULL,
    @PrecioMin       DECIMAL(18,2) = NULL,
    @PrecioMax       DECIMAL(18,2) = NULL,
    @SoloDisponibles BIT = 0,
    @Ordenar         VARCHAR(15) = 'NOMBRE_ASC',
    @Pagina          INT = 1,
    @TamanoPagina    INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    SET @Pagina = CASE WHEN @Pagina IS NULL OR @Pagina < 1 THEN 1 ELSE @Pagina END;
    SET @TamanoPagina = CASE WHEN @TamanoPagina IS NULL OR @TamanoPagina < 1 THEN 20
                             WHEN @TamanoPagina > 100 THEN 100 ELSE @TamanoPagina END;

    -- El texto se escapa: los comodines que escriba el usuario se tratan como texto literal
    DECLARE @Patron NVARCHAR(220) = NULL;
    IF @Texto IS NOT NULL AND LEN(LTRIM(RTRIM(@Texto))) > 0
        SET @Patron = N'%' + REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Texto)),
                      N'\', N'\\'), N'%', N'\%'), N'_', N'\_'), N'[', N'\[') + N'%';

    ;WITH Base AS (
        SELECT p.IDProducto,
               p.NombreProducto,
               p.Descripcion,
               p.IDCategoria,
               c.NombreCategoria,
               MIN(v.Precio) AS PrecioMin,
               MAX(v.Precio) AS PrecioMax,
               SUM(CASE WHEN d.Disponible > 0 THEN d.Disponible ELSE 0 END) AS Disponible,
               MIN(v.ImagenUrl) AS ImagenUrl
        FROM Productos p
        JOIN Categorias c ON c.IDCategoria = p.IDCategoria
        JOIN VariantesProducto v ON v.IDProducto = p.IDProducto AND v.Activo = 1
        JOIN FU_Inventario_Disponibilidad(NULL) d ON d.IDVariante = v.IDVariante
        WHERE p.Activo = 1
          AND c.Activo = 1
          AND (@IDCategoria IS NULL OR p.IDCategoria = @IDCategoria)
          AND (@PrecioMin IS NULL OR v.Precio >= @PrecioMin)
          AND (@PrecioMax IS NULL OR v.Precio <= @PrecioMax)
          AND (@Patron IS NULL
               OR p.NombreProducto LIKE @Patron ESCAPE N'\'
               OR p.Descripcion LIKE @Patron ESCAPE N'\'
               OR v.SKU LIKE @Patron ESCAPE N'\')
        GROUP BY p.IDProducto, p.NombreProducto, p.Descripcion, p.IDCategoria, c.NombreCategoria
        HAVING @SoloDisponibles = 0 OR SUM(CASE WHEN d.Disponible > 0 THEN d.Disponible ELSE 0 END) > 0
    )
    SELECT IDProducto, NombreProducto, Descripcion, IDCategoria, NombreCategoria,
           PrecioMin, PrecioMax, Disponible, ImagenUrl,
           COUNT(*) OVER() AS TotalRegistros
    FROM Base
    ORDER BY
        CASE WHEN @Ordenar = 'PRECIO_ASC'   THEN PrecioMin END ASC,
        CASE WHEN @Ordenar = 'PRECIO_DESC'  THEN PrecioMin END DESC,
        CASE WHEN @Ordenar = 'NOMBRE_DESC'  THEN NombreProducto END DESC,
        NombreProducto ASC,
        IDProducto
    OFFSET (@Pagina - 1) * @TamanoPagina ROWS FETCH NEXT @TamanoPagina ROWS ONLY;
END;
GO

-- Detalle de un producto con sus variantes y su disponibilidad.
-- @IncluirInactivos = 1 solo lo usa el backoffice.
CREATE OR ALTER PROCEDURE SP_Catalogo_ObtenerProducto
    @IDProducto        INT,
    @IncluirInactivos  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.IDProducto, p.NombreProducto, p.Descripcion, p.IDCategoria, c.NombreCategoria, p.Activo
    FROM Productos p
    JOIN Categorias c ON c.IDCategoria = p.IDCategoria
    WHERE p.IDProducto = @IDProducto AND (@IncluirInactivos = 1 OR (p.Activo = 1 AND c.Activo = 1));

    SELECT v.IDVariante, v.SKU, v.Talla, v.Color, v.Precio, v.ImagenUrl, v.Activo,
           d.ExistenciaFisica, d.Reservado,
           CASE WHEN d.Disponible > 0 THEN d.Disponible ELSE 0 END AS Disponible
    FROM VariantesProducto v
    JOIN FU_Inventario_Disponibilidad(NULL) d ON d.IDVariante = v.IDVariante
    JOIN Productos p ON p.IDProducto = v.IDProducto
    JOIN Categorias c ON c.IDCategoria = p.IDCategoria
    WHERE v.IDProducto = @IDProducto
      AND (@IncluirInactivos = 1 OR (v.Activo = 1 AND p.Activo = 1 AND c.Activo = 1))
    ORDER BY v.SKU;
END;
GO

------------------------------------------------------------------
-- Inventario
------------------------------------------------------------------

-- Libera las reservas que ya vencieron. La disponibilidad ya las ignora por fecha;
-- este procedimiento solo deja el estado al día (se puede ejecutar de forma periódica).
CREATE OR ALTER PROCEDURE SP_Inventario_LiberarReservasVencidas
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE ReservasExistencia
    SET Estado = 'VENCIDA'
    WHERE Estado = 'ACTIVA' AND FechaVencimiento <= SYSUTCDATETIME();
    SELECT @@ROWCOUNT AS ReservasLiberadas;
END;
GO

-- Entrada por compra (cantidad positiva) o ajuste manual (positivo o negativo).
-- Exige motivo y no deja la existencia en negativo ni por debajo de lo reservado.
CREATE OR ALTER PROCEDURE SP_Inventario_AjustarExistencia
    @IDVariante      INT,
    @TipoMovimiento  VARCHAR(20),
    @Cantidad        INT,
    @Motivo          NVARCHAR(255),
    @IDUsuarioAccion INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET LOCK_TIMEOUT 15000;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'PERSONAL';

    IF @TipoMovimiento NOT IN ('ENTRADA', 'AJUSTE')
        THROW 50134, N'Tipo de movimiento inválido. Use ENTRADA o AJUSTE.', 1;
    IF @Cantidad IS NULL OR @Cantidad = 0 OR (@TipoMovimiento = 'ENTRADA' AND @Cantidad < 0)
       OR @Cantidad > 1000000 OR @Cantidad < -1000000
        THROW 50135, N'La cantidad indicada no es válida para este movimiento (máximo 1,000,000).', 1;
    IF @Motivo IS NULL OR LEN(LTRIM(RTRIM(@Motivo))) = 0
        THROW 50133, N'El motivo es obligatorio.', 1;

    DECLARE @Actual INT, @Reservado INT, @Nuevo INT, @Antes NVARCHAR(MAX), @Despues NVARCHAR(MAX);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Bloquea la fila de la variante: movimientos simultáneos se ejecutan uno por uno
        SELECT @Actual = ExistenciaFisica FROM VariantesProducto WITH (UPDLOCK, HOLDLOCK) WHERE IDVariante = @IDVariante;
        IF @Actual IS NULL
            THROW 50124, N'La variante no existe.', 1;

        SELECT @Reservado = ISNULL(SUM(Cantidad), 0)
        FROM ReservasExistencia
        WHERE IDVariante = @IDVariante AND Estado = 'ACTIVA' AND FechaVencimiento > SYSUTCDATETIME();

        SET @Nuevo = @Actual + @Cantidad;

        IF @Nuevo < 0
            THROW 50131, N'El ajuste dejaría la existencia en negativo.', 1;
        IF @Nuevo < @Reservado
            THROW 50132, N'El ajuste dejaría la existencia por debajo de las unidades reservadas.', 1;

        INSERT INTO MovimientosInventario (IDVariante, IDUsuario, TipoMovimiento, Cantidad, ExistenciaResultante, Motivo)
        VALUES (@IDVariante, @IDUsuarioAccion, @TipoMovimiento, @Cantidad, @Nuevo, LTRIM(RTRIM(@Motivo)));

        UPDATE VariantesProducto SET ExistenciaFisica = @Nuevo WHERE IDVariante = @IDVariante;

        SET @Antes = (SELECT @IDVariante AS IDVariante, @Actual AS ExistenciaFisica FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @Despues = (SELECT @IDVariante AS IDVariante, @Nuevo AS ExistenciaFisica, @TipoMovimiento AS Tipo,
                               @Cantidad AS Cantidad, LTRIM(RTRIM(@Motivo)) AS Motivo
                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Inventario', 'VariantesProducto', @IDVariante, 'MODIFICAR', @Antes, @Despues;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @IDVariante AS IDVariante, @Nuevo AS ExistenciaFisica, @Nuevo - @Reservado AS Disponible;
END;
GO

-- Entradas por compra de varias variantes a la vez (TVP)
CREATE OR ALTER PROCEDURE SP_Inventario_RegistrarEntradas
    @Entradas        TT_Inventario_Entradas READONLY,
    @Motivo          NVARCHAR(255),
    @IDUsuarioAccion INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'PERSONAL';

    IF @Motivo IS NULL OR LEN(LTRIM(RTRIM(@Motivo))) = 0
        THROW 50133, N'El motivo es obligatorio.', 1;
    IF NOT EXISTS (SELECT 1 FROM @Entradas)
        THROW 50135, N'No se indicaron entradas.', 1;
    IF EXISTS (SELECT 1 FROM @Entradas e WHERE NOT EXISTS (SELECT 1 FROM VariantesProducto v WHERE v.IDVariante = e.IDVariante))
        THROW 50124, N'Una de las variantes indicadas no existe.', 1;

    CREATE TABLE #Mov (IDVariante INT NOT NULL, Cantidad INT NOT NULL, Antes INT NOT NULL, ExistenciaResultante INT NOT NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE v
        SET v.ExistenciaFisica = v.ExistenciaFisica + e.Cantidad
        OUTPUT inserted.IDVariante, e.Cantidad, deleted.ExistenciaFisica, inserted.ExistenciaFisica
        INTO #Mov (IDVariante, Cantidad, Antes, ExistenciaResultante)
        FROM VariantesProducto v
        JOIN @Entradas e ON e.IDVariante = v.IDVariante;

        INSERT INTO MovimientosInventario (IDVariante, IDUsuario, TipoMovimiento, Cantidad, ExistenciaResultante, Motivo)
        SELECT IDVariante, @IDUsuarioAccion, 'ENTRADA', Cantidad, ExistenciaResultante, LTRIM(RTRIM(@Motivo))
        FROM #Mov;

        INSERT INTO Bitacora (IDUsuario, Modulo, Entidad, IDEntidad, Accion, ValorAnterior, ValorNuevo)
        SELECT @IDUsuarioAccion, 'Inventario', 'VariantesProducto', CAST(IDVariante AS VARCHAR(50)), 'MODIFICAR',
               (SELECT m.IDVariante, m.Antes AS ExistenciaFisica FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
               (SELECT m.IDVariante, m.ExistenciaResultante AS ExistenciaFisica, 'ENTRADA' AS Tipo, m.Cantidad
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
        FROM #Mov m;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT IDVariante, Cantidad, ExistenciaResultante FROM #Mov ORDER BY IDVariante;
END;
GO

CREATE OR ALTER PROCEDURE SP_Inventario_ConsultarKardex
    @IDVariante       INT,
    @IDUsuarioAccion  INT,
    @Desde            DATE = NULL,
    @Hasta            DATE = NULL,
    @Pagina           INT = 1,
    @TamanoPagina     INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'PERSONAL';

    SET @Pagina = CASE WHEN @Pagina IS NULL OR @Pagina < 1 THEN 1 ELSE @Pagina END;
    SET @TamanoPagina = CASE WHEN @TamanoPagina IS NULL OR @TamanoPagina < 1 THEN 20
                             WHEN @TamanoPagina > 100 THEN 100 ELSE @TamanoPagina END;

    DECLARE @DesdeUTC DATETIME2(0) = NULL, @HastaUTC DATETIME2(0) = NULL;
    IF @Desde IS NOT NULL
        SET @DesdeUTC = CAST(CAST(@Desde AS DATETIME2(0)) AT TIME ZONE 'Central America Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(0));
    IF @Hasta IS NOT NULL
        SET @HastaUTC = CAST(CAST(DATEADD(DAY, 1, @Hasta) AS DATETIME2(0)) AT TIME ZONE 'Central America Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(0));

    SELECT m.IDMovimiento, v.SKU, m.TipoMovimiento, m.Cantidad, m.ExistenciaResultante, m.Motivo,
           m.FechaMovimiento, m.IDPedido, u.NombreCompleto AS Usuario,
           COUNT(*) OVER() AS TotalRegistros
    FROM MovimientosInventario m
    JOIN VariantesProducto v ON v.IDVariante = m.IDVariante
    JOIN Usuarios u ON u.IDUsuario = m.IDUsuario
    WHERE m.IDVariante = @IDVariante
      AND (@DesdeUTC IS NULL OR m.FechaMovimiento >= @DesdeUTC)
      AND (@HastaUTC IS NULL OR m.FechaMovimiento < @HastaUTC)
    ORDER BY m.FechaMovimiento DESC, m.IDMovimiento DESC
    OFFSET (@Pagina - 1) * @TamanoPagina ROWS FETCH NEXT @TamanoPagina ROWS ONLY;
END;
GO

CREATE OR ALTER PROCEDURE SP_Inventario_ListarExistencias
    @IDUsuarioAccion INT,
    @Texto           NVARCHAR(100) = NULL,
    @IDCategoria     INT = NULL,
    @Pagina          INT = 1,
    @TamanoPagina    INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'PERSONAL';

    SET @Pagina = CASE WHEN @Pagina IS NULL OR @Pagina < 1 THEN 1 ELSE @Pagina END;
    SET @TamanoPagina = CASE WHEN @TamanoPagina IS NULL OR @TamanoPagina < 1 THEN 20
                             WHEN @TamanoPagina > 100 THEN 100 ELSE @TamanoPagina END;

    DECLARE @Patron NVARCHAR(220) = NULL;
    IF @Texto IS NOT NULL AND LEN(LTRIM(RTRIM(@Texto))) > 0
        SET @Patron = N'%' + REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Texto)),
                      N'\', N'\\'), N'%', N'\%'), N'_', N'\_'), N'[', N'\[') + N'%';

    SELECT v.IDVariante, v.SKU, p.NombreProducto, c.NombreCategoria, v.Talla, v.Color, v.Activo,
           d.ExistenciaFisica, d.Reservado, d.Disponible,
           COUNT(*) OVER() AS TotalRegistros
    FROM VariantesProducto v
    JOIN FU_Inventario_Disponibilidad(NULL) d ON d.IDVariante = v.IDVariante
    JOIN Productos p ON p.IDProducto = v.IDProducto
    JOIN Categorias c ON c.IDCategoria = p.IDCategoria
    WHERE (@IDCategoria IS NULL OR p.IDCategoria = @IDCategoria)
      AND (@Patron IS NULL OR p.NombreProducto LIKE @Patron ESCAPE N'\' OR v.SKU LIKE @Patron ESCAPE N'\')
    ORDER BY p.NombreProducto, v.SKU
    OFFSET (@Pagina - 1) * @TamanoPagina ROWS FETCH NEXT @TamanoPagina ROWS ONLY;
END;
GO

-- Verifica que la existencia coincida con la suma del kardex. No debe devolver filas.
CREATE OR ALTER PROCEDURE SP_Inventario_VerificarKardex
AS
BEGIN
    SET NOCOUNT ON;
    SELECT v.IDVariante, v.SKU, v.ExistenciaFisica, ISNULL(SUM(m.Cantidad), 0) AS SumaKardex
    FROM VariantesProducto v
    LEFT JOIN MovimientosInventario m ON m.IDVariante = v.IDVariante
    GROUP BY v.IDVariante, v.SKU, v.ExistenciaFisica
    HAVING v.ExistenciaFisica <> ISNULL(SUM(m.Cantidad), 0);
END;
GO

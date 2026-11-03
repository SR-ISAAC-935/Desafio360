-- 016_Direcciones_Estados.sql
-- Procedimientos que faltaban para poder comprar desde la API:
--  * Direcciones de entrega del cliente (crear, listar, desactivar).
--  * Lista de estados del pedido (para los filtros).
-- Se ejecuta después de 012 y 014. Es re-ejecutable (CREATE OR ALTER).

-- Crea una dirección del cliente. Devuelve IDDireccion.
CREATE OR ALTER PROCEDURE SP_Direcciones_Crear
    @IDUsuario    INT,
    @Direccion    NVARCHAR(200),
    @Zona         NVARCHAR(10)  = NULL,
    @Municipio    NVARCHAR(100),
    @Departamento NVARCHAR(100),
    @Referencia   NVARCHAR(255) = NULL,
    @CodigoPostal VARCHAR(10)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Direccion = LTRIM(RTRIM(@Direccion));
    SET @Municipio = LTRIM(RTRIM(@Municipio));
    SET @Departamento = LTRIM(RTRIM(@Departamento));
    SET @Zona = NULLIF(LTRIM(RTRIM(@Zona)), N'');
    SET @Referencia = NULLIF(LTRIM(RTRIM(@Referencia)), N'');
    SET @CodigoPostal = NULLIF(LTRIM(RTRIM(@CodigoPostal)), '');

    IF @Direccion IS NULL OR LEN(@Direccion) = 0
       OR @Municipio IS NULL OR LEN(@Municipio) = 0
       OR @Departamento IS NULL OR LEN(@Departamento) = 0
        THROW 50126, N'La dirección, el municipio y el departamento son obligatorios.', 1;

    IF NOT EXISTS (SELECT 1 FROM Usuarios WHERE IDUsuario = @IDUsuario AND Activo = 1)
        THROW 50104, N'El usuario no existe o está inactivo.', 1;

    INSERT INTO Direcciones (IDUsuario, Direccion, Zona, Municipio, Departamento, Referencia, CodigoPostal)
    VALUES (@IDUsuario, @Direccion, @Zona, @Municipio, @Departamento, @Referencia, @CodigoPostal);

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS IDDireccion;
END;
GO

-- Direcciones activas del cliente (solo las suyas).
CREATE OR ALTER PROCEDURE SP_Direcciones_Listar
    @IDUsuario INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT IDDireccion, Direccion, Zona, Municipio, Departamento, Referencia, CodigoPostal, FechaCreacion
    FROM Direcciones
    WHERE IDUsuario = @IDUsuario AND Activo = 1
    ORDER BY IDDireccion DESC;
END;
GO

-- Desactiva una dirección propia (no se borra: los pedidos viejos la siguen usando).
CREATE OR ALTER PROCEDURE SP_Direcciones_Desactivar
    @IDDireccion INT,
    @IDUsuario   INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Dueno INT = (SELECT IDUsuario FROM Direcciones WHERE IDDireccion = @IDDireccion);

    IF @Dueno IS NULL
        THROW 50181, N'La dirección no existe.', 1;
    IF @Dueno <> @IDUsuario
        THROW 50182, N'La dirección no pertenece al cliente.', 1;

    UPDATE Direcciones SET Activo = 0 WHERE IDDireccion = @IDDireccion;
END;
GO

-- Estados del pedido (para llenar los filtros del frontend).
CREATE OR ALTER PROCEDURE SP_Pedidos_ListarEstados
AS
BEGIN
    SET NOCOUNT ON;
    SELECT IDEstadoPedido, NombreEstado FROM EstadosPedido ORDER BY IDEstadoPedido;
END;
GO

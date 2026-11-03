-- 00_Limpiar_Base.sql
-- Borra TODOS los objetos de ShopCart (tablas, procedimientos, funciones, vistas y tipos de tabla)
-- de la base a la que esté conectado, SIN borrar la base de datos (sirve para hosting compartido).
-- DESTRUCTIVO: se pierden todos los datos.

-- Seguridad: si está conectado a una base del sistema, TODO lo que sigue se omite (NOEXEC).
IF DB_NAME() IN (N'master', N'tempdb', N'model', N'msdb')
BEGIN
    PRINT N'ERROR: conéctese a la base de datos de ShopCart, no a una base del sistema. No se ejecutó nada.';
    SET NOEXEC ON;
END;
GO

DECLARE @sql NVARCHAR(MAX);
PRINT N'Limpiando la base: ' + DB_NAME();

-- 1) Llaves foráneas (para poder borrar las tablas en cualquier orden)
SELECT @sql = STRING_AGG(CAST(
    N'ALTER TABLE ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
  + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N';' AS NVARCHAR(MAX)), NCHAR(10))
FROM sys.foreign_keys fk
JOIN sys.tables t ON t.object_id = fk.parent_object_id;
IF @sql IS NOT NULL EXEC sp_executesql @sql;

-- 2) Vistas, procedimientos y funciones (en ese orden)
SET @sql = NULL;
SELECT @sql = STRING_AGG(CAST(
    N'DROP ' + CASE o.type WHEN 'V' THEN N'VIEW' WHEN 'P' THEN N'PROCEDURE' ELSE N'FUNCTION' END
  + N' ' + QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name) + N';' AS NVARCHAR(MAX)), NCHAR(10))
  WITHIN GROUP (ORDER BY CASE o.type WHEN 'V' THEN 1 WHEN 'P' THEN 2 ELSE 3 END)
FROM sys.objects o
WHERE o.is_ms_shipped = 0 AND o.type IN ('V', 'P', 'FN', 'IF', 'TF');
IF @sql IS NOT NULL EXEC sp_executesql @sql;

-- 3) Tablas (sus triggers y restricciones se van con ellas)
SET @sql = NULL;
SELECT @sql = STRING_AGG(CAST(
    N'DROP TABLE ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name) + N';' AS NVARCHAR(MAX)), NCHAR(10))
FROM sys.tables t
WHERE t.is_ms_shipped = 0;
IF @sql IS NOT NULL EXEC sp_executesql @sql;

-- 4) Tipos de tabla (TVP). Van al final porque los procedimientos ya no los usan.
SET @sql = NULL;
SELECT @sql = STRING_AGG(CAST(
    N'DROP TYPE ' + QUOTENAME(SCHEMA_NAME(ty.schema_id)) + N'.' + QUOTENAME(ty.name) + N';' AS NVARCHAR(MAX)), NCHAR(10))
FROM sys.types ty
WHERE ty.is_table_type = 1 AND ty.is_user_defined = 1;
IF @sql IS NOT NULL EXEC sp_executesql @sql;

-- Comprobación: debe quedar en cero
SELECT (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0)                                   AS TablasRestantes,
       (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND type IN ('V','P','FN','IF','TF')) AS ProgramabilidadRestante,
       (SELECT COUNT(*) FROM sys.types WHERE is_table_type = 1 AND is_user_defined = 1)             AS TiposRestantes;
GO

-- ============ INSTALACIÓN (001 a 012 + 014) ============
-- Instalar_Remoto.sql: esquema completo SIN crear ni borrar la base de datos.
-- Úselo conectado a una base ya creada y VACÍA (por ejemplo la de un hosting).
-- Si ya hay objetos de ShopCart, no lo ejecute: falla porque las tablas ya existen.

-- ===== 001_Acceso.sql =====
-- 001_Acceso.sql
-- Módulo de acceso: roles, usuarios y refresh tokens.

CREATE TABLE Roles (
    IDRol     INT IDENTITY(1,1) NOT NULL,
    NombreRol NVARCHAR(50)      NOT NULL,
    CONSTRAINT PK_Roles PRIMARY KEY (IDRol),
    CONSTRAINT UQ_Roles_NombreRol UNIQUE (NombreRol)
);
GO

CREATE TABLE Usuarios (
    IDUsuario     INT IDENTITY(1,1) NOT NULL,
    Email         NVARCHAR(150)     NOT NULL,
    NombreCompleto NVARCHAR(150)    NOT NULL,
    PasswordHash  VARCHAR(255)      NOT NULL,
    IDRol         INT               NOT NULL,
    Activo        BIT               NOT NULL CONSTRAINT DF_Usuarios_Activo DEFAULT 1,
    FechaCreacion DATETIME2(0)      NOT NULL CONSTRAINT DF_Usuarios_FechaCreacion DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Usuarios PRIMARY KEY (IDUsuario),
    CONSTRAINT UQ_Usuarios_Email UNIQUE (Email),
    CONSTRAINT CK_Usuarios_Email CHECK (Email LIKE '%_@_%._%'),
    CONSTRAINT FK_Usuarios_Roles FOREIGN KEY (IDRol) REFERENCES Roles (IDRol)
);
GO

CREATE INDEX IX_Usuarios_IDRol ON Usuarios (IDRol);
GO

CREATE TABLE RefreshTokens (
    IDToken           INT IDENTITY(1,1) NOT NULL,
    IDUsuario         INT               NOT NULL,
    TokenHash         CHAR(64)          NOT NULL,   -- SHA-256 en hexadecimal
    FechaCreacion     DATETIME2(0)      NOT NULL CONSTRAINT DF_RefreshTokens_FechaCreacion DEFAULT SYSUTCDATETIME(),
    FechaExpiracion   DATETIME2(0)      NOT NULL,
    FechaRevocacion   DATETIME2(0)      NULL,
    IDTokenReemplazo  INT               NULL,       -- token que lo reemplazó en la rotación
    DispositivoID     UNIQUEIDENTIFIER  NULL,
    DireccionIP       VARCHAR(45)       NULL,
    CONSTRAINT PK_RefreshTokens PRIMARY KEY (IDToken),
    CONSTRAINT UQ_RefreshTokens_TokenHash UNIQUE (TokenHash),
    CONSTRAINT FK_RefreshTokens_Usuarios FOREIGN KEY (IDUsuario) REFERENCES Usuarios (IDUsuario),
    CONSTRAINT FK_RefreshTokens_Reemplazo FOREIGN KEY (IDTokenReemplazo) REFERENCES RefreshTokens (IDToken),
    CONSTRAINT CK_RefreshTokens_Expiracion CHECK (FechaExpiracion > FechaCreacion),
    CONSTRAINT CK_RefreshTokens_NoSiMismo CHECK (IDTokenReemplazo IS NULL OR IDTokenReemplazo <> IDToken)
);
GO

CREATE INDEX IX_RefreshTokens_IDUsuario ON RefreshTokens (IDUsuario);
GO

-- Solo un token activo por usuario y dispositivo (los revocados no cuentan)
CREATE UNIQUE INDEX UX_RefreshTokens_DispositivoActivo
    ON RefreshTokens (IDUsuario, DispositivoID)
    WHERE FechaRevocacion IS NULL AND DispositivoID IS NOT NULL;
GO

-- Semillas de roles
INSERT INTO Roles (NombreRol) VALUES (N'Cliente'), (N'Operador'), (N'Administrador');
GO

GO

-- ===== 002_Catalogo_Inventario.sql =====
-- 002_Catalogo_Inventario.sql
-- Catálogo (categorías, productos, variantes) e inventario (kardex).
-- Los precios publicados incluyen IVA del 12 %.

CREATE TABLE Categorias (
    IDCategoria    INT IDENTITY(1,1) NOT NULL,
    NombreCategoria NVARCHAR(100)    NOT NULL,
    Descripcion    NVARCHAR(500)     NULL,
    Activo         BIT               NOT NULL CONSTRAINT DF_Categorias_Activo DEFAULT 1,
    FechaCreacion  DATETIME2(0)      NOT NULL CONSTRAINT DF_Categorias_FechaCreacion DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Categorias PRIMARY KEY (IDCategoria),
    CONSTRAINT UQ_Categorias_Nombre UNIQUE (NombreCategoria)
);
GO

CREATE TABLE Productos (
    IDProducto     INT IDENTITY(1,1) NOT NULL,
    NombreProducto NVARCHAR(150)     NOT NULL,
    IDCategoria    INT               NOT NULL,
    Descripcion    NVARCHAR(1000)    NULL,
    Activo         BIT               NOT NULL CONSTRAINT DF_Productos_Activo DEFAULT 1,
    FechaCreacion  DATETIME2(0)      NOT NULL CONSTRAINT DF_Productos_FechaCreacion DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Productos PRIMARY KEY (IDProducto),
    CONSTRAINT UQ_Productos_Nombre UNIQUE (NombreProducto),
    CONSTRAINT FK_Productos_Categorias FOREIGN KEY (IDCategoria) REFERENCES Categorias (IDCategoria)
);
GO

CREATE INDEX IX_Productos_IDCategoria ON Productos (IDCategoria);
GO

-- Variante vendible: tiene su propio SKU, precio y existencia física.
CREATE TABLE VariantesProducto (
    IDVariante        INT IDENTITY(1,1) NOT NULL,
    IDProducto        INT               NOT NULL,
    SKU               VARCHAR(50)       NOT NULL,
    Talla             NVARCHAR(30)      NULL,
    Color             NVARCHAR(30)      NULL,
    Precio            DECIMAL(18,2)     NOT NULL,   -- incluye IVA
    ExistenciaFisica  INT               NOT NULL CONSTRAINT DF_Variantes_Existencia DEFAULT 0,
    ImagenUrl         NVARCHAR(255)     NULL,
    Activo            BIT               NOT NULL CONSTRAINT DF_Variantes_Activo DEFAULT 1,
    FechaCreacion     DATETIME2(0)      NOT NULL CONSTRAINT DF_Variantes_FechaCreacion DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_VariantesProducto PRIMARY KEY (IDVariante),
    CONSTRAINT UQ_VariantesProducto_SKU UNIQUE (SKU),
    CONSTRAINT FK_VariantesProducto_Productos FOREIGN KEY (IDProducto) REFERENCES Productos (IDProducto),
    CONSTRAINT CK_VariantesProducto_Precio CHECK (Precio >= 0),
    CONSTRAINT CK_VariantesProducto_Existencia CHECK (ExistenciaFisica >= 0)
);
GO

CREATE INDEX IX_VariantesProducto_IDProducto ON VariantesProducto (IDProducto);
GO

-- Kardex: cantidad con signo (entradas y devoluciones positivas, salidas negativas,
-- ajustes en cualquier sentido). La existencia física = suma de las cantidades.
CREATE TABLE MovimientosInventario (
    IDMovimiento        INT IDENTITY(1,1) NOT NULL,
    IDVariante          INT               NOT NULL,
    IDUsuario           INT               NOT NULL,
    TipoMovimiento      VARCHAR(20)       NOT NULL,
    Cantidad            INT               NOT NULL,
    ExistenciaResultante INT              NOT NULL,   -- saldo después del movimiento
    Motivo              NVARCHAR(255)     NOT NULL,
    FechaMovimiento     DATETIME2(0)      NOT NULL CONSTRAINT DF_Movimientos_Fecha DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_MovimientosInventario PRIMARY KEY (IDMovimiento),
    CONSTRAINT FK_Movimientos_Variantes FOREIGN KEY (IDVariante) REFERENCES VariantesProducto (IDVariante),
    CONSTRAINT FK_Movimientos_Usuarios FOREIGN KEY (IDUsuario) REFERENCES Usuarios (IDUsuario),
    CONSTRAINT CK_Movimientos_Tipo CHECK (TipoMovimiento IN ('ENTRADA', 'SALIDA', 'AJUSTE', 'DEVOLUCION')),
    CONSTRAINT CK_Movimientos_Cantidad CHECK (Cantidad <> 0),
    CONSTRAINT CK_Movimientos_Signo CHECK (
        (TipoMovimiento IN ('ENTRADA', 'DEVOLUCION') AND Cantidad > 0)
        OR (TipoMovimiento = 'SALIDA' AND Cantidad < 0)
        OR TipoMovimiento = 'AJUSTE'
    ),
    CONSTRAINT CK_Movimientos_Saldo CHECK (ExistenciaResultante >= 0),
    CONSTRAINT CK_Movimientos_Motivo CHECK (LEN(LTRIM(RTRIM(Motivo))) > 0)
);
GO

CREATE INDEX IX_Movimientos_Variante_Fecha ON MovimientosInventario (IDVariante, FechaMovimiento);
GO

-- Pendiente: agregar IDPedido (nulable) cuando exista la tabla Pedidos.

GO

-- ===== 003_Direcciones_Carrito_Cupones_Pedidos.sql =====
-- 003_Direcciones_Carrito_Cupones_Pedidos.sql
-- Direcciones, cupones, carrito, catálogo de estados del pedido y pedidos.
-- Los precios publicados incluyen IVA del 12 %: el IVA se calcula, no se suma.
-- Orden de creación respeta las dependencias (Cupones antes de Carritos y Pedidos).

CREATE TABLE Direcciones (
    IDDireccion   INT IDENTITY(1,1) NOT NULL,
    IDUsuario     INT               NOT NULL,
    Direccion     NVARCHAR(200)     NOT NULL,
    Zona          NVARCHAR(10)      NULL,
    Municipio     NVARCHAR(100)     NOT NULL,
    Departamento  NVARCHAR(100)     NOT NULL,
    Referencia    NVARCHAR(255)     NULL,
    CodigoPostal  VARCHAR(10)       NULL,
    Activo        BIT               NOT NULL CONSTRAINT DF_Direcciones_Activo DEFAULT 1,
    FechaCreacion DATETIME2(0)      NOT NULL CONSTRAINT DF_Direcciones_FechaCreacion DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Direcciones PRIMARY KEY (IDDireccion),
    CONSTRAINT FK_Direcciones_Usuarios FOREIGN KEY (IDUsuario) REFERENCES Usuarios (IDUsuario)
);
GO

CREATE INDEX IX_Direcciones_IDUsuario ON Direcciones (IDUsuario);
GO

CREATE TABLE Cupones (
    IDCupon              INT IDENTITY(1,1) NOT NULL,
    Codigo               VARCHAR(50)       NOT NULL,
    Descripcion          NVARCHAR(255)     NULL,
    Tipo                 VARCHAR(15)       NOT NULL,   -- PORCENTAJE | MONTO_FIJO
    Valor                DECIMAL(18,2)     NOT NULL,
    FechaInicio          DATETIME2(0)      NOT NULL,
    FechaFin             DATETIME2(0)      NOT NULL,
    MontoMinimo          DECIMAL(18,2)     NOT NULL CONSTRAINT DF_Cupones_MontoMinimo DEFAULT 0,
    LimiteUsosTotal      INT               NOT NULL,
    UsosActuales         INT               NOT NULL CONSTRAINT DF_Cupones_UsosActuales DEFAULT 0,
    LimiteUsosPorCliente INT               NOT NULL CONSTRAINT DF_Cupones_LimiteCliente DEFAULT 1,
    IDCategoria          INT               NULL,       -- NULL = aplica a todo el carrito
    Activo               BIT               NOT NULL CONSTRAINT DF_Cupones_Activo DEFAULT 1,
    FechaCreacion        DATETIME2(0)      NOT NULL CONSTRAINT DF_Cupones_FechaCreacion DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Cupones PRIMARY KEY (IDCupon),
    CONSTRAINT UQ_Cupones_Codigo UNIQUE (Codigo),
    CONSTRAINT FK_Cupones_Categorias FOREIGN KEY (IDCategoria) REFERENCES Categorias (IDCategoria),
    CONSTRAINT CK_Cupones_Tipo CHECK (Tipo IN ('PORCENTAJE', 'MONTO_FIJO')),
    CONSTRAINT CK_Cupones_Valor CHECK (Valor > 0 AND (Tipo <> 'PORCENTAJE' OR Valor <= 100)),
    CONSTRAINT CK_Cupones_Vigencia CHECK (FechaFin > FechaInicio),
    CONSTRAINT CK_Cupones_MontoMinimo CHECK (MontoMinimo >= 0),
    CONSTRAINT CK_Cupones_Limites CHECK (LimiteUsosTotal > 0 AND LimiteUsosPorCliente > 0),
    -- Protección en base de datos: nunca se pasa del límite total aunque haya concurrencia
    CONSTRAINT CK_Cupones_Usos CHECK (UsosActuales >= 0 AND UsosActuales <= LimiteUsosTotal)
);
GO

CREATE TABLE Carritos (
    IDCarrito             INT IDENTITY(1,1) NOT NULL,
    IDUsuario             INT               NULL,
    TokenInvitado         UNIQUEIDENTIFIER  NULL,
    IDCupon               INT               NULL,
    Estado                VARCHAR(15)       NOT NULL CONSTRAINT DF_Carritos_Estado DEFAULT 'ACTIVO',
    FechaCreacion         DATETIME2(0)      NOT NULL CONSTRAINT DF_Carritos_FechaCreacion DEFAULT SYSUTCDATETIME(),
    FechaUltimaActividad  DATETIME2(0)      NOT NULL CONSTRAINT DF_Carritos_UltimaActividad DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Carritos PRIMARY KEY (IDCarrito),
    CONSTRAINT FK_Carritos_Usuarios FOREIGN KEY (IDUsuario) REFERENCES Usuarios (IDUsuario),
    CONSTRAINT FK_Carritos_Cupones FOREIGN KEY (IDCupon) REFERENCES Cupones (IDCupon),
    CONSTRAINT CK_Carritos_Estado CHECK (Estado IN ('ACTIVO', 'CONVERTIDO', 'ABANDONADO')),
    CONSTRAINT CK_Carritos_Dueno CHECK (IDUsuario IS NOT NULL OR TokenInvitado IS NOT NULL)
);
GO

CREATE UNIQUE INDEX UX_Carritos_TokenInvitado
    ON Carritos (TokenInvitado) WHERE TokenInvitado IS NOT NULL;
CREATE UNIQUE INDEX UX_Carritos_UsuarioActivo
    ON Carritos (IDUsuario) WHERE IDUsuario IS NOT NULL AND Estado = 'ACTIVO';
GO

-- El precio se lee de la variante; se congela al crear el pedido.
CREATE TABLE CarritoDetalle (
    IDCarritoDetalle INT IDENTITY(1,1) NOT NULL,
    IDCarrito        INT               NOT NULL,
    IDVariante       INT               NOT NULL,
    Cantidad         INT               NOT NULL,
    FechaAgregado    DATETIME2(0)      NOT NULL CONSTRAINT DF_CarritoDetalle_Fecha DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_CarritoDetalle PRIMARY KEY (IDCarritoDetalle),
    CONSTRAINT UQ_CarritoDetalle_Variante UNIQUE (IDCarrito, IDVariante),
    CONSTRAINT FK_CarritoDetalle_Carritos FOREIGN KEY (IDCarrito) REFERENCES Carritos (IDCarrito),
    CONSTRAINT FK_CarritoDetalle_Variantes FOREIGN KEY (IDVariante) REFERENCES VariantesProducto (IDVariante),
    CONSTRAINT CK_CarritoDetalle_Cantidad CHECK (Cantidad > 0)
);
GO

CREATE TABLE EstadosPedido (
    IDEstadoPedido INT IDENTITY(1,1) NOT NULL,
    NombreEstado   NVARCHAR(50)      NOT NULL,
    CONSTRAINT PK_EstadosPedido PRIMARY KEY (IDEstadoPedido),
    CONSTRAINT UQ_EstadosPedido_Nombre UNIQUE (NombreEstado)
);
GO

-- Estados propuestos (documentar el diagrama de transiciones en el README)
INSERT INTO EstadosPedido (NombreEstado) VALUES
    (N'Pendiente de pago'), (N'Pagado'), (N'En preparación'), (N'Despachado'),
    (N'Entregado'), (N'Cancelado'), (N'Devuelto parcial'), (N'Devuelto');
GO

CREATE TABLE Pedidos (
    IDPedido            INT IDENTITY(1,1) NOT NULL,
    IDUsuario           INT               NOT NULL,
    IDDireccion         INT               NOT NULL,
    IDEstadoPedido      INT               NOT NULL,
    IDCupon             INT               NULL,
    Subtotal            DECIMAL(18,2)     NOT NULL,   -- con IVA incluido
    Descuento           DECIMAL(18,2)     NOT NULL CONSTRAINT DF_Pedidos_Descuento DEFAULT 0,
    Total               DECIMAL(18,2)     NOT NULL,
    MontoIVA            DECIMAL(18,2)     NOT NULL,   -- IVA contenido en el total (Total * 12 / 112)
    LlaveIdempotencia   VARCHAR(64)       NOT NULL,
    FechaPedido         DATETIME2(0)      NOT NULL CONSTRAINT DF_Pedidos_Fecha DEFAULT SYSUTCDATETIME(),
    Version             ROWVERSION,
    CONSTRAINT PK_Pedidos PRIMARY KEY (IDPedido),
    CONSTRAINT UQ_Pedidos_Idempotencia UNIQUE (IDUsuario, LlaveIdempotencia),
    CONSTRAINT FK_Pedidos_Usuarios FOREIGN KEY (IDUsuario) REFERENCES Usuarios (IDUsuario),
    CONSTRAINT FK_Pedidos_Direcciones FOREIGN KEY (IDDireccion) REFERENCES Direcciones (IDDireccion),
    CONSTRAINT FK_Pedidos_EstadosPedido FOREIGN KEY (IDEstadoPedido) REFERENCES EstadosPedido (IDEstadoPedido),
    CONSTRAINT FK_Pedidos_Cupones FOREIGN KEY (IDCupon) REFERENCES Cupones (IDCupon),
    CONSTRAINT CK_Pedidos_Montos CHECK (Subtotal >= 0 AND Descuento >= 0 AND Descuento <= Subtotal AND MontoIVA >= 0),
    CONSTRAINT CK_Pedidos_Total CHECK (Total = Subtotal - Descuento)   -- nunca por debajo de cero
);
GO

CREATE INDEX IX_Pedidos_Usuario ON Pedidos (IDUsuario, FechaPedido);
CREATE INDEX IX_Pedidos_Estado_Fecha ON Pedidos (IDEstadoPedido, FechaPedido);
GO

CREATE TABLE PedidoDetalle (
    IDPedidoDetalle  INT IDENTITY(1,1) NOT NULL,
    IDPedido         INT               NOT NULL,
    IDVariante       INT               NOT NULL,
    Cantidad         INT               NOT NULL,
    PrecioUnitario   DECIMAL(18,2)     NOT NULL,   -- congelado al comprar
    DescuentoLinea   DECIMAL(18,2)     NOT NULL CONSTRAINT DF_PedidoDetalle_Descuento DEFAULT 0,
    TotalLinea       DECIMAL(18,2)     NOT NULL,
    CantidadDevuelta INT               NOT NULL CONSTRAINT DF_PedidoDetalle_Devuelta DEFAULT 0,
    CONSTRAINT PK_PedidoDetalle PRIMARY KEY (IDPedidoDetalle),
    CONSTRAINT UQ_PedidoDetalle_Variante UNIQUE (IDPedido, IDVariante),
    CONSTRAINT FK_PedidoDetalle_Pedidos FOREIGN KEY (IDPedido) REFERENCES Pedidos (IDPedido),
    CONSTRAINT FK_PedidoDetalle_Variantes FOREIGN KEY (IDVariante) REFERENCES VariantesProducto (IDVariante),
    CONSTRAINT CK_PedidoDetalle_Cantidad CHECK (Cantidad > 0),
    CONSTRAINT CK_PedidoDetalle_Precio CHECK (PrecioUnitario >= 0 AND DescuentoLinea >= 0),
    CONSTRAINT CK_PedidoDetalle_Total CHECK (TotalLinea = Cantidad * PrecioUnitario - DescuentoLinea AND TotalLinea >= 0),
    -- No se puede devolver más de lo vendido en la línea
    CONSTRAINT CK_PedidoDetalle_Devuelta CHECK (CantidadDevuelta >= 0 AND CantidadDevuelta <= Cantidad)
);
GO

CREATE TABLE UsosCupon (
    IDUsoCupon INT IDENTITY(1,1) NOT NULL,
    IDCupon    INT               NOT NULL,
    IDUsuario  INT               NOT NULL,
    IDPedido   INT               NOT NULL,
    FechaUso   DATETIME2(0)      NOT NULL CONSTRAINT DF_UsosCupon_Fecha DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_UsosCupon PRIMARY KEY (IDUsoCupon),
    CONSTRAINT UQ_UsosCupon_Pedido UNIQUE (IDPedido),     -- un cupón por pedido
    CONSTRAINT FK_UsosCupon_Cupones FOREIGN KEY (IDCupon) REFERENCES Cupones (IDCupon),
    CONSTRAINT FK_UsosCupon_Usuarios FOREIGN KEY (IDUsuario) REFERENCES Usuarios (IDUsuario),
    CONSTRAINT FK_UsosCupon_Pedidos FOREIGN KEY (IDPedido) REFERENCES Pedidos (IDPedido)
);
GO

CREATE INDEX IX_UsosCupon_Cupon_Usuario ON UsosCupon (IDCupon, IDUsuario);
GO

-- Cierra el pendiente del kardex: relación opcional con el pedido que originó el movimiento.
ALTER TABLE MovimientosInventario ADD IDPedido INT NULL;
GO
ALTER TABLE MovimientosInventario
    ADD CONSTRAINT FK_Movimientos_Pedidos FOREIGN KEY (IDPedido) REFERENCES Pedidos (IDPedido);
GO

GO

-- ===== 004_Reservas_Estados_Pagos_Devoluciones_Bitacora.sql =====
-- 004_Reservas_Estados_Pagos_Devoluciones_Bitacora.sql
-- Reservas de existencia, transiciones e historial de estados del pedido,
-- pagos, devoluciones y bitácora inmutable.

------------------------------------------------------------------
-- Reservas de existencia (15 minutos durante el checkout)
-- Disponible = ExistenciaFisica - SUM(Cantidad) de reservas ACTIVAS no vencidas
------------------------------------------------------------------
CREATE TABLE ReservasExistencia (
    IDReserva        INT IDENTITY(1,1) NOT NULL,
    IDCarrito        INT               NOT NULL,
    IDVariante       INT               NOT NULL,
    Cantidad         INT               NOT NULL,
    Estado           VARCHAR(15)       NOT NULL CONSTRAINT DF_Reservas_Estado DEFAULT 'ACTIVA',
    FechaCreacion    DATETIME2(0)      NOT NULL CONSTRAINT DF_Reservas_FechaCreacion DEFAULT SYSUTCDATETIME(),
    FechaVencimiento DATETIME2(0)      NOT NULL,
    IDPedido         INT               NULL,       -- se llena al confirmar el pago
    CONSTRAINT PK_ReservasExistencia PRIMARY KEY (IDReserva),
    CONSTRAINT FK_Reservas_Carritos FOREIGN KEY (IDCarrito) REFERENCES Carritos (IDCarrito),
    CONSTRAINT FK_Reservas_Variantes FOREIGN KEY (IDVariante) REFERENCES VariantesProducto (IDVariante),
    CONSTRAINT FK_Reservas_Pedidos FOREIGN KEY (IDPedido) REFERENCES Pedidos (IDPedido),
    CONSTRAINT CK_Reservas_Cantidad CHECK (Cantidad > 0),
    CONSTRAINT CK_Reservas_Estado CHECK (Estado IN ('ACTIVA', 'CONFIRMADA', 'LIBERADA', 'VENCIDA')),
    CONSTRAINT CK_Reservas_Vencimiento CHECK (FechaVencimiento > FechaCreacion)
);
GO

-- Una sola reserva activa por carrito y variante
CREATE UNIQUE INDEX UX_Reservas_CarritoVarianteActiva
    ON ReservasExistencia (IDCarrito, IDVariante) WHERE Estado = 'ACTIVA';
-- Para calcular la disponibilidad y para liberar reservas vencidas
CREATE INDEX IX_Reservas_Variante_Estado_Vencimiento
    ON ReservasExistencia (IDVariante, Estado, FechaVencimiento) INCLUDE (Cantidad);
GO

------------------------------------------------------------------
-- Transiciones permitidas del pedido (la base de datos también las valida)
------------------------------------------------------------------
CREATE TABLE TransicionesEstadoPedido (
    IDEstadoOrigen  INT NOT NULL,
    IDEstadoDestino INT NOT NULL,
    CONSTRAINT PK_TransicionesEstadoPedido PRIMARY KEY (IDEstadoOrigen, IDEstadoDestino),
    CONSTRAINT FK_Transiciones_Origen FOREIGN KEY (IDEstadoOrigen) REFERENCES EstadosPedido (IDEstadoPedido),
    CONSTRAINT FK_Transiciones_Destino FOREIGN KEY (IDEstadoDestino) REFERENCES EstadosPedido (IDEstadoPedido),
    CONSTRAINT CK_Transiciones_Distintos CHECK (IDEstadoOrigen <> IDEstadoDestino)
);
GO

INSERT INTO TransicionesEstadoPedido (IDEstadoOrigen, IDEstadoDestino)
SELECT o.IDEstadoPedido, d.IDEstadoPedido
FROM (VALUES
    (N'Pendiente de pago', N'Pagado'),
    (N'Pendiente de pago', N'Cancelado'),
    (N'Pagado',            N'En preparación'),
    (N'Pagado',            N'Cancelado'),
    (N'En preparación',    N'Despachado'),
    (N'En preparación',    N'Cancelado'),
    (N'Despachado',        N'Entregado'),
    (N'Entregado',         N'Devuelto parcial'),
    (N'Entregado',         N'Devuelto'),
    (N'Devuelto parcial',  N'Devuelto')
) AS t (Origen, Destino)
JOIN EstadosPedido o ON o.NombreEstado = t.Origen
JOIN EstadosPedido d ON d.NombreEstado = t.Destino;
GO

CREATE TABLE HistorialEstadosPedido (
    IDHistorial      INT IDENTITY(1,1) NOT NULL,
    IDPedido         INT               NOT NULL,
    IDEstadoAnterior INT               NULL,       -- NULL en la creación del pedido
    IDEstadoNuevo    INT               NOT NULL,
    IDUsuario        INT               NOT NULL,
    FechaCambio      DATETIME2(0)      NOT NULL CONSTRAINT DF_HistorialEstados_Fecha DEFAULT SYSUTCDATETIME(),
    Comentario       NVARCHAR(255)     NULL,
    CONSTRAINT PK_HistorialEstadosPedido PRIMARY KEY (IDHistorial),
    CONSTRAINT FK_HistorialEstados_Pedidos FOREIGN KEY (IDPedido) REFERENCES Pedidos (IDPedido),
    CONSTRAINT FK_HistorialEstados_Anterior FOREIGN KEY (IDEstadoAnterior) REFERENCES EstadosPedido (IDEstadoPedido),
    CONSTRAINT FK_HistorialEstados_Nuevo FOREIGN KEY (IDEstadoNuevo) REFERENCES EstadosPedido (IDEstadoPedido),
    CONSTRAINT FK_HistorialEstados_Usuarios FOREIGN KEY (IDUsuario) REFERENCES Usuarios (IDUsuario)
);
GO

CREATE INDEX IX_HistorialEstados_Pedido ON HistorialEstadosPedido (IDPedido, FechaCambio);
GO

-- Rechaza en la base de datos cualquier cambio de estado no permitido
CREATE TRIGGER TR_Pedidos_ValidarTransicion
ON Pedidos
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE(IDEstadoPedido)
       AND EXISTS (
            SELECT 1
            FROM inserted i
            JOIN deleted d ON d.IDPedido = i.IDPedido
            WHERE i.IDEstadoPedido <> d.IDEstadoPedido
              AND NOT EXISTS (
                    SELECT 1 FROM TransicionesEstadoPedido t
                    WHERE t.IDEstadoOrigen = d.IDEstadoPedido
                      AND t.IDEstadoDestino = i.IDEstadoPedido))
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50001, N'Transición de estado del pedido no permitida.', 1;
    END
END;
GO

------------------------------------------------------------------
-- Pagos (simulados). Un reintento con la misma llave no crea otro cobro.
------------------------------------------------------------------
CREATE TABLE Pagos (
    IDPago            INT IDENTITY(1,1) NOT NULL,
    IDPedido          INT               NOT NULL,
    Monto             DECIMAL(18,2)     NOT NULL,
    Metodo            VARCHAR(30)       NOT NULL,
    Estado            VARCHAR(15)       NOT NULL,
    Referencia        VARCHAR(100)      NULL,
    LlaveIdempotencia VARCHAR(64)       NOT NULL,
    FechaPago         DATETIME2(0)      NOT NULL CONSTRAINT DF_Pagos_Fecha DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Pagos PRIMARY KEY (IDPago),
    CONSTRAINT UQ_Pagos_Idempotencia UNIQUE (LlaveIdempotencia),
    CONSTRAINT FK_Pagos_Pedidos FOREIGN KEY (IDPedido) REFERENCES Pedidos (IDPedido),
    CONSTRAINT CK_Pagos_Monto CHECK (Monto > 0),
    CONSTRAINT CK_Pagos_Estado CHECK (Estado IN ('PENDIENTE', 'APROBADO', 'RECHAZADO', 'REEMBOLSADO'))
);
GO

CREATE INDEX IX_Pagos_Pedido ON Pagos (IDPedido);
-- Máximo un pago aprobado por pedido
CREATE UNIQUE INDEX UX_Pagos_PedidoAprobado ON Pagos (IDPedido) WHERE Estado = 'APROBADO';
GO

------------------------------------------------------------------
-- Devoluciones (totales o parciales, por línea de pedido)
------------------------------------------------------------------
CREATE TABLE Devoluciones (
    IDDevolucion     INT IDENTITY(1,1) NOT NULL,
    IDPedido         INT               NOT NULL,
    IDUsuario        INT               NOT NULL,     -- quien registra la devolución
    Tipo             VARCHAR(10)       NOT NULL,
    Motivo           NVARCHAR(255)     NOT NULL,
    MontoReembolso   DECIMAL(18,2)     NOT NULL,
    FechaDevolucion  DATETIME2(0)      NOT NULL CONSTRAINT DF_Devoluciones_Fecha DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Devoluciones PRIMARY KEY (IDDevolucion),
    CONSTRAINT FK_Devoluciones_Pedidos FOREIGN KEY (IDPedido) REFERENCES Pedidos (IDPedido),
    CONSTRAINT FK_Devoluciones_Usuarios FOREIGN KEY (IDUsuario) REFERENCES Usuarios (IDUsuario),
    CONSTRAINT CK_Devoluciones_Tipo CHECK (Tipo IN ('TOTAL', 'PARCIAL')),
    CONSTRAINT CK_Devoluciones_Monto CHECK (MontoReembolso >= 0),
    CONSTRAINT CK_Devoluciones_Motivo CHECK (LEN(LTRIM(RTRIM(Motivo))) > 0)
);
GO

CREATE INDEX IX_Devoluciones_Pedido ON Devoluciones (IDPedido);
GO

CREATE TABLE DevolucionDetalle (
    IDDevolucionDetalle INT IDENTITY(1,1) NOT NULL,
    IDDevolucion        INT               NOT NULL,
    IDPedidoDetalle     INT               NOT NULL,
    Cantidad            INT               NOT NULL,
    CONSTRAINT PK_DevolucionDetalle PRIMARY KEY (IDDevolucionDetalle),
    CONSTRAINT UQ_DevolucionDetalle_Linea UNIQUE (IDDevolucion, IDPedidoDetalle),
    CONSTRAINT FK_DevolucionDetalle_Devoluciones FOREIGN KEY (IDDevolucion) REFERENCES Devoluciones (IDDevolucion),
    CONSTRAINT FK_DevolucionDetalle_PedidoDetalle FOREIGN KEY (IDPedidoDetalle) REFERENCES PedidoDetalle (IDPedidoDetalle),
    CONSTRAINT CK_DevolucionDetalle_Cantidad CHECK (Cantidad > 0)
);
GO

-- El tope de lo devuelto por línea lo protege PedidoDetalle.CantidadDevuelta <= Cantidad.

------------------------------------------------------------------
-- Bitácora: solo se inserta; no se modifica ni se elimina
------------------------------------------------------------------
CREATE TABLE Bitacora (
    IDBitacora    BIGINT IDENTITY(1,1) NOT NULL,
    IDUsuario     INT               NOT NULL,
    FechaHora     DATETIME2(3)      NOT NULL CONSTRAINT DF_Bitacora_Fecha DEFAULT SYSUTCDATETIME(),
    Modulo        VARCHAR(30)       NOT NULL,   -- Productos, Precios, Inventario, Cupones, Pedidos
    Entidad       VARCHAR(50)       NOT NULL,
    IDEntidad     VARCHAR(50)       NOT NULL,
    Accion        VARCHAR(15)       NOT NULL,
    ValorAnterior NVARCHAR(MAX)     NULL,       -- JSON
    ValorNuevo    NVARCHAR(MAX)     NULL,       -- JSON
    CONSTRAINT PK_Bitacora PRIMARY KEY (IDBitacora),
    CONSTRAINT FK_Bitacora_Usuarios FOREIGN KEY (IDUsuario) REFERENCES Usuarios (IDUsuario),
    CONSTRAINT CK_Bitacora_Accion CHECK (Accion IN ('CREAR', 'MODIFICAR', 'DESACTIVAR')),
    CONSTRAINT CK_Bitacora_JsonAnterior CHECK (ValorAnterior IS NULL OR ISJSON(ValorAnterior) = 1),
    CONSTRAINT CK_Bitacora_JsonNuevo CHECK (ValorNuevo IS NULL OR ISJSON(ValorNuevo) = 1)
);
GO

CREATE INDEX IX_Bitacora_Modulo_Fecha ON Bitacora (Modulo, FechaHora);
GO

CREATE TRIGGER TR_Bitacora_Inmutable
ON Bitacora
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50002, N'La bitácora no puede modificarse ni eliminarse.', 1;
END;
GO

-- Recomendado en el despliegue: el usuario de la aplicación solo tiene EXECUTE sobre
-- los SP, sin permisos directos sobre las tablas (y DENY UPDATE, DELETE sobre Bitacora).

GO

-- ===== 005_Semillas.sql =====
-- 005_Semillas.sql
-- Datos de prueba reproducibles. Contraseña de los tres usuarios: Prueba123!
-- (hash bcrypt, costo 10; si el backend usa otro algoritmo, hay que regenerarlo)

-- Usuarios (los roles ya se sembraron en 001)
INSERT INTO Usuarios (Email, NombreCompleto, PasswordHash, IDRol)
SELECT v.Email, v.Nombre, '$2b$10$Ailom9WojMktAMpW1OrMnOGqU3mOCvD1eypu/FH.U6voXEjmNLaNO', r.IDRol
FROM (VALUES
    (N'admin@shopcart.test',    N'Administrador ShopCart', N'Administrador'),
    (N'operador@shopcart.test', N'Operador ShopCart',      N'Operador'),
    (N'cliente@shopcart.test',  N'Cliente de Prueba',      N'Cliente')
) AS v (Email, Nombre, Rol)
JOIN Roles r ON r.NombreRol = v.Rol;
GO

INSERT INTO Direcciones (IDUsuario, Direccion, Zona, Municipio, Departamento, Referencia)
SELECT IDUsuario, N'5a avenida 10-20', N'1', N'Guatemala', N'Guatemala', N'Casa blanca, portón negro'
FROM Usuarios WHERE Email = N'cliente@shopcart.test';
GO

-- Categorías
INSERT INTO Categorias (NombreCategoria, Descripcion) VALUES
    (N'Ropa',        N'Camisas, pantalones y prendas de vestir'),
    (N'Calzado',     N'Zapatos y tenis'),
    (N'Accesorios',  N'Gorras, mochilas y cinturones'),
    (N'Electrónica', N'Audífonos y dispositivos');
GO

-- Productos
INSERT INTO Productos (NombreProducto, IDCategoria, Descripcion)
SELECT v.Nombre, c.IDCategoria, v.Descripcion
FROM (VALUES
    (N'Camisa Polo',        N'Ropa',        N'Camisa polo de algodón'),
    (N'Pantalón Jeans',     N'Ropa',        N'Jeans corte recto'),
    (N'Sudadera con capucha', N'Ropa',      N'Sudadera de felpa'),
    (N'Tenis Running',      N'Calzado',     N'Tenis ligeros para correr'),
    (N'Zapato Casual',      N'Calzado',     N'Zapato de cuero casual'),
    (N'Gorra Clásica',      N'Accesorios',  N'Gorra ajustable'),
    (N'Mochila Urbana',     N'Accesorios',  N'Mochila para laptop de 15 pulgadas'),
    (N'Audífonos Bluetooth', N'Electrónica', N'Audífonos inalámbricos'),
    (N'Cargador Rápido',    N'Electrónica', N'Cargador USB-C de 30 W')
) AS v (Nombre, Categoria, Descripcion)
JOIN Categorias c ON c.NombreCategoria = v.Categoria;
GO

-- Variantes (existencia inicial; el kardex se genera abajo con el mismo valor)
INSERT INTO VariantesProducto (IDProducto, SKU, Talla, Color, Precio, ExistenciaFisica)
SELECT p.IDProducto, v.SKU, v.Talla, v.Color, v.Precio, v.Existencia
FROM (VALUES
    (N'Camisa Polo',    'POLO-M-AZ',  N'M',  N'Azul',   149.00, 50),
    (N'Camisa Polo',    'POLO-L-AZ',  N'L',  N'Azul',   149.00, 40),
    (N'Camisa Polo',    'POLO-M-BL',  N'M',  N'Blanco', 149.00, 30),
    (N'Camisa Polo',    'POLO-L-BL',  N'L',  N'Blanco', 149.00, 1),
    (N'Pantalón Jeans', 'JEAN-30-AZ', N'30', N'Azul',   249.00, 25),
    (N'Pantalón Jeans', 'JEAN-32-AZ', N'32', N'Azul',   249.00, 25),
    (N'Pantalón Jeans', 'JEAN-34-NG', N'34', N'Negro',  259.00, 20),
    (N'Sudadera con capucha', 'SUD-M-GR', N'M', N'Gris',  199.00, 35),
    (N'Sudadera con capucha', 'SUD-L-GR', N'L', N'Gris',  199.00, 35),
    (N'Tenis Running',  'TEN-40-NG',  N'40', N'Negro',  399.00, 15),
    (N'Tenis Running',  'TEN-42-NG',  N'42', N'Negro',  399.00, 15),
    (N'Tenis Running',  'TEN-42-BL',  N'42', N'Blanco', 399.00, 12),
    (N'Zapato Casual',  'ZAP-41-CF',  N'41', N'Café',   449.00, 10),
    (N'Zapato Casual',  'ZAP-43-CF',  N'43', N'Café',   449.00, 10),
    (N'Gorra Clásica',  'GOR-U-NG',   NULL,  N'Negro',   75.00, 100),
    (N'Gorra Clásica',  'GOR-U-RJ',   NULL,  N'Rojo',    75.00, 80),
    (N'Mochila Urbana', 'MOC-U-GR',   NULL,  N'Gris',   299.00, 22),
    (N'Audífonos Bluetooth', 'AUD-BT-NG', NULL, N'Negro', 349.00, 18),
    (N'Cargador Rápido', 'CAR-30W',   NULL,  N'Blanco',  99.00, 60)
) AS v (Producto, SKU, Talla, Color, Precio, Existencia)
JOIN Productos p ON p.NombreProducto = v.Producto;
GO

-- Kardex: entrada inicial por cada variante, así existencia = suma del kardex
INSERT INTO MovimientosInventario (IDVariante, IDUsuario, TipoMovimiento, Cantidad, ExistenciaResultante, Motivo)
SELECT v.IDVariante,
       (SELECT IDUsuario FROM Usuarios WHERE Email = N'admin@shopcart.test'),
       'ENTRADA', v.ExistenciaFisica, v.ExistenciaFisica, N'Inventario inicial'
FROM VariantesProducto v
WHERE v.ExistenciaFisica > 0;
GO

-- Cupones
INSERT INTO Cupones (Codigo, Descripcion, Tipo, Valor, FechaInicio, FechaFin, MontoMinimo, LimiteUsosTotal, LimiteUsosPorCliente, IDCategoria)
VALUES
    ('BIENVENIDO10', N'10 % de descuento en todo el carrito', 'PORCENTAJE', 10,
     '2026-10-01', '2027-12-31', 100, 1000, 1, NULL),
    ('ENVIO25',      N'Q25 de descuento en compras desde Q200', 'MONTO_FIJO', 25,
     '2026-10-01', '2027-12-31', 200, 500, 2, NULL),
    ('ROPA15',       N'15 % solo en la categoría Ropa', 'PORCENTAJE', 15,
     '2026-10-01', '2027-12-31', 0, 300, 1, (SELECT IDCategoria FROM Categorias WHERE NombreCategoria = N'Ropa')),
    ('VENCIDO5',     N'Cupón vencido para pruebas', 'PORCENTAJE', 5,
     '2025-01-01', '2025-12-31', 0, 100, 1, NULL);
GO

-- Cupón agotado para pruebas
INSERT INTO Cupones (Codigo, Descripcion, Tipo, Valor, FechaInicio, FechaFin, MontoMinimo, LimiteUsosTotal, UsosActuales, LimiteUsosPorCliente)
VALUES ('AGOTADO20', N'Cupón agotado para pruebas', 'PORCENTAJE', 20, '2026-10-01', '2027-12-31', 0, 5, 5, 1);
GO

GO

-- ===== 006_Indices.sql =====
-- 006_Indices.sql
-- Índices adicionales para las consultas más frecuentes.
-- Los PK, UNIQUE y varios índices de FK ya se crearon en los scripts 001 a 004.
-- Validar cada uno con el plan de ejecución real una vez escritos los SP.

-- Catálogo: listar variantes activas de un producto con precio y existencia sin ir a la tabla
CREATE INDEX IX_VariantesProducto_Activas
    ON VariantesProducto (IDProducto, Activo)
    INCLUDE (SKU, Precio, ExistenciaFisica);

-- Catálogo: filtro por categoría solo de productos activos
CREATE INDEX IX_Productos_Categoria_Activo
    ON Productos (IDCategoria, Activo)
    INCLUDE (NombreProducto);

-- Reportes: ventas por rango de fechas y estado
CREATE INDEX IX_Pedidos_Fecha_Estado
    ON Pedidos (FechaPedido, IDEstadoPedido)
    INCLUDE (Total, IDUsuario);

-- Reportes: productos más vendidos y ventas por categoría
CREATE INDEX IX_PedidoDetalle_Variante
    ON PedidoDetalle (IDVariante)
    INCLUDE (IDPedido, Cantidad, TotalLinea, CantidadDevuelta);

-- Carritos abandonados: búsqueda por estado y última actividad
CREATE INDEX IX_Carritos_Estado_Actividad
    ON Carritos (Estado, FechaUltimaActividad);

-- Detalle del carrito por variante (revisar existencia al agregar)
CREATE INDEX IX_CarritoDetalle_Variante
    ON CarritoDetalle (IDVariante);

-- Cupones vigentes
CREATE INDEX IX_Cupones_Vigencia
    ON Cupones (Activo, FechaInicio, FechaFin);

-- Búsqueda por texto: LIKE '%texto%' no usa índices normales.
-- Opciones: LIKE 'texto%' (usa índice) o un índice de texto completo (Full-Text Search),
-- si está disponible en tu instalación de SQL Server.

GO

-- ===== 007_Tipos_Funciones_Vistas.sql =====
-- 007_Tipos_Funciones_Vistas.sql
-- Tipos de tabla (TVP), funciones tipo tabla y vistas que usan los stored procedures.

-- Precio visto al iniciar el pago: se congela en la reserva (se compara al crear el pedido)
IF COL_LENGTH('ReservasExistencia', 'PrecioUnitario') IS NULL
    ALTER TABLE ReservasExistencia ADD PrecioUnitario DECIMAL(18,2) NULL;
GO

------------------------------------------------------------------
-- TVP: parámetros con valores de tabla (se reciben siempre READONLY)
------------------------------------------------------------------
IF TYPE_ID(N'TT_Catalogo_Variantes') IS NULL
CREATE TYPE TT_Catalogo_Variantes AS TABLE (
    SKU               VARCHAR(50)   NOT NULL PRIMARY KEY,
    Talla             NVARCHAR(30)  NULL,
    Color             NVARCHAR(30)  NULL,
    Precio            DECIMAL(18,2) NOT NULL CHECK (Precio BETWEEN 0 AND 9999999.99),
    ExistenciaInicial INT           NOT NULL CHECK (ExistenciaInicial BETWEEN 0 AND 1000000),
    ImagenUrl         NVARCHAR(255) NULL
);
GO

IF TYPE_ID(N'TT_Inventario_Entradas') IS NULL
CREATE TYPE TT_Inventario_Entradas AS TABLE (
    IDVariante INT NOT NULL PRIMARY KEY,
    Cantidad   INT NOT NULL CHECK (Cantidad BETWEEN 1 AND 1000000)
);
GO

IF TYPE_ID(N'TT_Devoluciones_Lineas') IS NULL
CREATE TYPE TT_Devoluciones_Lineas AS TABLE (
    IDPedidoDetalle INT NOT NULL PRIMARY KEY,
    Cantidad        INT NOT NULL CHECK (Cantidad BETWEEN 1 AND 1000)
);
GO

------------------------------------------------------------------
-- Disponibilidad = existencia física - reservas ACTIVAS y no vencidas.
-- Una reserva vencida deja de contar sola, sin intervención manual.
-- @IDCarritoExcluir: no cuenta las reservas de ese carrito (NULL = cuenta todas).
------------------------------------------------------------------
CREATE OR ALTER FUNCTION FU_Inventario_Disponibilidad (@IDCarritoExcluir INT)
RETURNS TABLE
AS
RETURN
(
    SELECT v.IDVariante,
           v.ExistenciaFisica,
           ISNULL(r.Reservado, 0) AS Reservado,
           v.ExistenciaFisica - ISNULL(r.Reservado, 0) AS Disponible
    FROM VariantesProducto v
    LEFT JOIN (
        SELECT IDVariante, SUM(Cantidad) AS Reservado
        FROM ReservasExistencia
        WHERE Estado = 'ACTIVA'
          AND FechaVencimiento > SYSUTCDATETIME()
          AND (@IDCarritoExcluir IS NULL OR IDCarrito <> @IDCarritoExcluir)
        GROUP BY IDVariante
    ) r ON r.IDVariante = v.IDVariante
);
GO

------------------------------------------------------------------
-- Descuento de un cupón sobre un carrito. El descuento nunca supera la base aplicable,
-- por lo que el total jamás queda por debajo de cero. Se redondea una sola vez.
------------------------------------------------------------------
CREATE OR ALTER FUNCTION FU_Cupones_CalculoDescuento (@IDCupon INT, @IDCarrito INT)
RETURNS TABLE
AS
RETURN
(
    SELECT c.IDCupon,
           b.BaseAplicable,
           CAST(CASE
                    WHEN c.Tipo = 'PORCENTAJE' THEN ROUND(b.BaseAplicable * c.Valor / 100.0, 2)
                    WHEN c.Valor < b.BaseAplicable THEN c.Valor
                    ELSE b.BaseAplicable
                END AS DECIMAL(18,2)) AS Descuento
    FROM Cupones c
    CROSS APPLY (
        SELECT CAST(ISNULL(SUM(cd.Cantidad * v.Precio), 0) AS DECIMAL(18,2)) AS BaseAplicable
        FROM CarritoDetalle cd
        JOIN VariantesProducto v ON v.IDVariante = cd.IDVariante
        JOIN Productos p ON p.IDProducto = v.IDProducto
        WHERE cd.IDCarrito = @IDCarrito
          AND (c.IDCategoria IS NULL OR p.IDCategoria = c.IDCategoria)
    ) b
    WHERE c.IDCupon = @IDCupon
);
GO

------------------------------------------------------------------
-- Reportes: solo pedidos "completados" = todos menos Pendiente de pago, Cancelado y
-- Devuelto (total). Las devoluciones parciales se descuentan del total.
-- FechaLocal usa la zona horaria de Guatemala.
------------------------------------------------------------------
CREATE OR ALTER VIEW VW_Reportes_PedidosCompletados
AS
SELECT p.IDPedido,
       p.IDUsuario,
       p.IDEstadoPedido,
       p.FechaPedido,
       CAST(p.FechaPedido AT TIME ZONE 'UTC' AT TIME ZONE 'Central America Standard Time' AS DATE) AS FechaLocal,
       p.Total,
       ISNULL(d.MontoDevuelto, 0) AS MontoDevuelto,
       p.Total - ISNULL(d.MontoDevuelto, 0) AS TotalNeto
FROM Pedidos p
JOIN EstadosPedido e ON e.IDEstadoPedido = p.IDEstadoPedido
LEFT JOIN (
    SELECT IDPedido, SUM(MontoReembolso) AS MontoDevuelto
    FROM Devoluciones
    GROUP BY IDPedido
) d ON d.IDPedido = p.IDPedido
WHERE e.NombreEstado NOT IN (N'Pendiente de pago', N'Cancelado', N'Devuelto');
GO

CREATE OR ALTER VIEW VW_Reportes_LineasVendidas
AS
SELECT pc.FechaLocal,
       pd.IDPedido,
       pd.IDVariante,
       p.IDProducto,
       p.NombreProducto,
       c.IDCategoria,
       c.NombreCategoria,
       pd.Cantidad - pd.CantidadDevuelta AS UnidadesNetas,
       pd.TotalLinea - ROUND(pd.TotalLinea * pd.CantidadDevuelta / pd.Cantidad, 2) AS MontoNeto
FROM PedidoDetalle pd
JOIN VW_Reportes_PedidosCompletados pc ON pc.IDPedido = pd.IDPedido
JOIN VariantesProducto v ON v.IDVariante = pd.IDVariante
JOIN Productos p ON p.IDProducto = v.IDProducto
JOIN Categorias c ON c.IDCategoria = p.IDCategoria;
GO

GO

-- ===== 008_SP_Acceso.sql =====
-- 008_SP_Acceso.sql
-- Auxiliares (bitácora y permisos) y procedimientos de autenticación y usuarios.
--
-- CÓDIGOS DE ERROR (THROW). El backend los traduce a HTTP:
--   50001 transición de estado no permitida (trigger)      -> 409
--   50002 bitácora inmutable (trigger)                     -> 403
--   50003 kardex, historial, pedidos y pagos no se modifican ni eliminan (trigger) -> 403
--   50199 procedimiento auxiliar fuera de transacción (error de programación) -> 500
--   SQL Server: 1205 deadlock -> reintentar la solicitud 1-2 veces;  1222 tiempo de bloqueo agotado -> 503
--   50101 correo duplicado -> 409      50103 sin permisos -> 403     50104 usuario no existe -> 404
--   50105 no puede desactivarse a sí mismo -> 409            50106 rol inexistente -> 400
--   50111 refresh token inválido -> 401   50112 reuso de token -> 401   50113 expirado -> 401
--   50114 usuario inactivo -> 403
--   50121 duplicado en catálogo -> 409   50122 categoría inválida -> 400   50123 producto no existe -> 404
--   50124 variante no existe -> 404      50125 producto sin variantes -> 400   50126 datos inválidos -> 400
--   50131 existencia negativa -> 409     50132 bajo lo reservado -> 409   50133 motivo obligatorio -> 400
--   50134 tipo de movimiento inválido -> 400   50135 cantidad inválida -> 400
--   50141 carrito no existe -> 404   50142 carrito ajeno -> 403   50143 producto no disponible -> 409
--   50144 excede existencia -> 409   50145 carrito inactivo -> 409   50146 línea inexistente -> 404
--   50147 cantidad inválida -> 400
--   50151..50159 cupones al aplicar (ver SP_Cupones_Validar)   50161 código duplicado -> 409
--   50162 datos de cupón inválidos -> 400   50163 cupón no existe -> 404
--   50171 carrito con productos no disponibles -> 409   50172 sin existencia suficiente -> 409
--   50173 carrito vacío -> 400   50174 reserva vencida -> 409   50175 el precio cambió -> 409
--   50181 dirección inválida -> 400   50182 dirección ajena -> 403   50183 pedido ajeno -> 403
--   50184 pedido no existe -> 404   50190 no se obtuvo el bloqueo -> 503
--   50191 estado no asignable por esta vía -> 400   50192 transición no permitida -> 409
--   50193 estado inexistente -> 400
--   50201 pedido no admite devolución -> 409   50202 línea ajena al pedido -> 400
--   50203 devolución excede lo vendido -> 409   50204 devolución sin líneas -> 400
--   50211 parámetro de reporte inválido -> 400

------------------------------------------------------------------
-- Auxiliares
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Bitacora_Registrar
    @IDUsuario     INT,
    @Modulo        VARCHAR(30),
    @Entidad       VARCHAR(50),
    @IDEntidad     VARCHAR(50),
    @Accion        VARCHAR(15),
    @ValorAnterior NVARCHAR(MAX) = NULL,
    @ValorNuevo    NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO Bitacora (IDUsuario, Modulo, Entidad, IDEntidad, Accion, ValorAnterior, ValorNuevo)
    VALUES (@IDUsuario, @Modulo, @Entidad, @IDEntidad, @Accion, @ValorAnterior, @ValorNuevo);
END;
GO

-- @Nivel: 'ADMIN' (solo Administrador) o 'PERSONAL' (Operador o Administrador)
CREATE OR ALTER PROCEDURE SP_Usuarios_ExigirRol
    @IDUsuario INT,
    @Nivel     VARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (
        SELECT 1
        FROM Usuarios u
        JOIN Roles r ON r.IDRol = u.IDRol
        WHERE u.IDUsuario = @IDUsuario
          AND u.Activo = 1
          AND (   (@Nivel = 'ADMIN'    AND r.NombreRol = N'Administrador')
               OR (@Nivel = 'PERSONAL' AND r.NombreRol IN (N'Administrador', N'Operador'))))
        THROW 50103, N'No tiene permisos para realizar esta acción.', 1;
END;
GO

------------------------------------------------------------------
-- Autenticación
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Auth_RegistrarCliente
    @Email          NVARCHAR(150),
    @NombreCompleto NVARCHAR(150),
    @PasswordHash   VARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @IDRol INT = (SELECT IDRol FROM Roles WHERE NombreRol = N'Cliente');
    DECLARE @IDUsuario INT;

    BEGIN TRY
        INSERT INTO Usuarios (Email, NombreCompleto, PasswordHash, IDRol)
        VALUES (LOWER(LTRIM(RTRIM(@Email))), LTRIM(RTRIM(@NombreCompleto)), @PasswordHash, @IDRol);
        SET @IDUsuario = SCOPE_IDENTITY();
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() IN (2601, 2627)
            THROW 50101, N'El correo ya está registrado.', 1;
        THROW;
    END CATCH;

    SELECT u.IDUsuario, u.Email, u.NombreCompleto, r.NombreRol
    FROM Usuarios u
    JOIN Roles r ON r.IDRol = u.IDRol
    WHERE u.IDUsuario = @IDUsuario;
END;
GO

-- El backend compara la contraseña con PasswordHash (bcrypt); nunca se compara en SQL.
CREATE OR ALTER PROCEDURE SP_Auth_ObtenerUsuarioPorEmail
    @Email NVARCHAR(150)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.IDUsuario, u.Email, u.NombreCompleto, u.PasswordHash, u.Activo, u.IDRol, r.NombreRol
    FROM Usuarios u
    JOIN Roles r ON r.IDRol = u.IDRol
    WHERE u.Email = LOWER(LTRIM(RTRIM(@Email)));
END;
GO

CREATE OR ALTER PROCEDURE SP_Auth_ObtenerUsuarioPorID
    @IDUsuario INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.IDUsuario, u.Email, u.NombreCompleto, u.Activo, u.IDRol, r.NombreRol
    FROM Usuarios u
    JOIN Roles r ON r.IDRol = u.IDRol
    WHERE u.IDUsuario = @IDUsuario;
END;
GO

CREATE OR ALTER PROCEDURE SP_Auth_GuardarRefreshToken
    @IDUsuario       INT,
    @TokenHash       CHAR(64),
    @FechaExpiracion DATETIME2(0),
    @DispositivoID   UNIQUEIDENTIFIER = NULL,
    @DireccionIP     VARCHAR(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Una sola sesión activa por dispositivo: se revoca la anterior
        IF @DispositivoID IS NOT NULL
            UPDATE RefreshTokens
            SET FechaRevocacion = SYSUTCDATETIME()
            WHERE IDUsuario = @IDUsuario AND DispositivoID = @DispositivoID AND FechaRevocacion IS NULL;

        INSERT INTO RefreshTokens (IDUsuario, TokenHash, FechaExpiracion, DispositivoID, DireccionIP)
        VALUES (@IDUsuario, @TokenHash, @FechaExpiracion, @DispositivoID, @DireccionIP);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

-- Rotación: el token actual se revoca y se emite uno nuevo. Si llega un token ya revocado
-- se asume robo: se revocan todas las sesiones del usuario.
CREATE OR ALTER PROCEDURE SP_Auth_RotarRefreshToken
    @TokenHashActual      CHAR(64),
    @TokenHashNuevo       CHAR(64),
    @FechaExpiracionNueva DATETIME2(0),
    @DireccionIP          VARCHAR(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @IDToken INT, @IDUsuario INT, @Revocado DATETIME2(0), @Expira DATETIME2(0),
            @Dispositivo UNIQUEIDENTIFIER, @UsuarioActivo BIT, @IDTokenNuevo INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @IDToken = t.IDToken, @IDUsuario = t.IDUsuario, @Revocado = t.FechaRevocacion,
               @Expira = t.FechaExpiracion, @Dispositivo = t.DispositivoID, @UsuarioActivo = u.Activo
        FROM RefreshTokens t WITH (UPDLOCK, HOLDLOCK)
        JOIN Usuarios u ON u.IDUsuario = t.IDUsuario
        WHERE t.TokenHash = @TokenHashActual;

        IF @IDToken IS NULL
            THROW 50111, N'Refresh token inválido.', 1;

        IF @Revocado IS NOT NULL
        BEGIN
            UPDATE RefreshTokens
            SET FechaRevocacion = SYSUTCDATETIME()
            WHERE IDUsuario = @IDUsuario AND FechaRevocacion IS NULL;
            COMMIT TRANSACTION;
            THROW 50112, N'Se detectó reutilización de un token. Todas las sesiones fueron cerradas.', 1;
        END;

        IF @Expira <= SYSUTCDATETIME()
            THROW 50113, N'El refresh token expiró.', 1;

        IF @UsuarioActivo = 0
            THROW 50114, N'El usuario está desactivado.', 1;

        -- Primero se revoca el actual (libera el índice único del dispositivo)
        UPDATE RefreshTokens SET FechaRevocacion = SYSUTCDATETIME() WHERE IDToken = @IDToken;

        INSERT INTO RefreshTokens (IDUsuario, TokenHash, FechaExpiracion, DispositivoID, DireccionIP)
        VALUES (@IDUsuario, @TokenHashNuevo, @FechaExpiracionNueva, @Dispositivo, @DireccionIP);
        SET @IDTokenNuevo = SCOPE_IDENTITY();

        UPDATE RefreshTokens SET IDTokenReemplazo = @IDTokenNuevo WHERE IDToken = @IDToken;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT u.IDUsuario, u.Email, u.NombreCompleto, r.NombreRol
    FROM Usuarios u
    JOIN Roles r ON r.IDRol = u.IDRol
    WHERE u.IDUsuario = @IDUsuario;
END;
GO

CREATE OR ALTER PROCEDURE SP_Auth_RevocarRefreshToken
    @TokenHash CHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE RefreshTokens
    SET FechaRevocacion = SYSUTCDATETIME()
    WHERE TokenHash = @TokenHash AND FechaRevocacion IS NULL;
END;
GO

------------------------------------------------------------------
-- Usuarios (Administrador)
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Usuarios_Crear
    @Email           NVARCHAR(150),
    @NombreCompleto  NVARCHAR(150),
    @PasswordHash    VARCHAR(255),
    @NombreRol       NVARCHAR(50),
    @IDUsuarioAccion INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    DECLARE @IDRol INT = (SELECT IDRol FROM Roles WHERE NombreRol = @NombreRol);
    IF @IDRol IS NULL
        THROW 50106, N'El rol indicado no existe.', 1;

    DECLARE @IDUsuario INT, @Json NVARCHAR(MAX);

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO Usuarios (Email, NombreCompleto, PasswordHash, IDRol)
        VALUES (LOWER(LTRIM(RTRIM(@Email))), LTRIM(RTRIM(@NombreCompleto)), @PasswordHash, @IDRol);
        SET @IDUsuario = SCOPE_IDENTITY();

        SET @Json = (SELECT IDUsuario, Email, NombreCompleto, IDRol, Activo
                     FROM Usuarios WHERE IDUsuario = @IDUsuario
                     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Usuarios', 'Usuarios', @IDUsuario, 'CREAR', NULL, @Json;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() IN (2601, 2627)
            THROW 50101, N'El correo ya está registrado.', 1;
        THROW;
    END CATCH;

    SELECT @IDUsuario AS IDUsuario;
END;
GO

-- Desactiva o reactiva un usuario sin borrarlo; al desactivar se cierran sus sesiones.
CREATE OR ALTER PROCEDURE SP_Usuarios_CambiarEstado
    @IDUsuario       INT,
    @Activo          BIT,
    @IDUsuarioAccion INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    IF NOT EXISTS (SELECT 1 FROM Usuarios WHERE IDUsuario = @IDUsuario)
        THROW 50104, N'El usuario no existe.', 1;

    IF @IDUsuario = @IDUsuarioAccion AND @Activo = 0
        THROW 50105, N'No puede desactivar su propio usuario.', 1;

    DECLARE @Antes NVARCHAR(MAX), @Despues NVARCHAR(MAX);
    DECLARE @Accion VARCHAR(15) = CASE WHEN @Activo = 0 THEN 'DESACTIVAR' ELSE 'MODIFICAR' END;

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @Antes = (SELECT IDUsuario, Email, Activo FROM Usuarios WHERE IDUsuario = @IDUsuario
                      FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        UPDATE Usuarios SET Activo = @Activo WHERE IDUsuario = @IDUsuario;

        IF @Activo = 0
            UPDATE RefreshTokens SET FechaRevocacion = SYSUTCDATETIME()
            WHERE IDUsuario = @IDUsuario AND FechaRevocacion IS NULL;

        SET @Despues = (SELECT IDUsuario, Email, Activo FROM Usuarios WHERE IDUsuario = @IDUsuario
                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Usuarios', 'Usuarios', @IDUsuario,
             @Accion, @Antes, @Despues;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE SP_Usuarios_Listar
    @IDUsuarioAccion INT,
    @Buscar          NVARCHAR(100) = NULL,
    @NombreRol       NVARCHAR(50)  = NULL,
    @Activo          BIT           = NULL,
    @Pagina          INT           = 1,
    @TamanoPagina    INT           = 20
AS
BEGIN
    SET NOCOUNT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    SET @Pagina = CASE WHEN @Pagina IS NULL OR @Pagina < 1 THEN 1 ELSE @Pagina END;
    SET @TamanoPagina = CASE WHEN @TamanoPagina IS NULL OR @TamanoPagina < 1 THEN 20
                             WHEN @TamanoPagina > 100 THEN 100 ELSE @TamanoPagina END;

    DECLARE @Patron NVARCHAR(220) = NULL;
    IF @Buscar IS NOT NULL AND LEN(LTRIM(RTRIM(@Buscar))) > 0
        SET @Patron = N'%' + REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Buscar)),
                      N'\', N'\\'), N'%', N'\%'), N'_', N'\_'), N'[', N'\[') + N'%';

    SELECT u.IDUsuario, u.Email, u.NombreCompleto, r.NombreRol, u.Activo, u.FechaCreacion,
           COUNT(*) OVER() AS TotalRegistros
    FROM Usuarios u
    JOIN Roles r ON r.IDRol = u.IDRol
    WHERE (@Patron IS NULL OR u.Email LIKE @Patron ESCAPE N'\' OR u.NombreCompleto LIKE @Patron ESCAPE N'\')
      AND (@NombreRol IS NULL OR r.NombreRol = @NombreRol)
      AND (@Activo IS NULL OR u.Activo = @Activo)
    ORDER BY u.NombreCompleto, u.IDUsuario
    OFFSET (@Pagina - 1) * @TamanoPagina ROWS FETCH NEXT @TamanoPagina ROWS ONLY;
END;
GO

GO

-- ===== 009_SP_Catalogo_Inventario.sql =====
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

GO

-- ===== 010_SP_Carrito_Cupones.sql =====
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

GO

-- ===== 011_SP_Checkout_Pedidos.sql =====
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

GO

-- ===== 012_SP_Reportes_Bitacora.sql =====
-- 012_SP_Reportes_Bitacora.sql
-- Dashboard y reportes (Administrador) y consulta de la bitácora.
-- Los reportes consideran solo pedidos completados: excluyen Pendiente de pago, Cancelado y
-- Devuelto (total), y descuentan las devoluciones parciales. Las fechas se agrupan en hora de Guatemala.

------------------------------------------------------------------
-- Ventas por día, semana o mes (@Agrupacion: DIA | SEMANA | MES; semana inicia en lunes)
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Reportes_VentasPorPeriodo
    @IDUsuarioAccion INT,
    @Desde           DATE,
    @Hasta           DATE,
    @Agrupacion      VARCHAR(10) = 'DIA'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    IF @Agrupacion NOT IN ('DIA', 'SEMANA', 'MES')
        THROW 50211, N'La agrupación debe ser DIA, SEMANA o MES.', 1;
    IF @Desde IS NULL OR @Hasta IS NULL OR @Hasta < @Desde
        THROW 50211, N'El rango de fechas no es válido.', 1;

    SELECT x.Periodo,
           COUNT(*) AS NumeroPedidos,
           SUM(pc.TotalNeto) AS TotalVendido,
           CAST(ROUND(SUM(pc.TotalNeto) / COUNT(*), 2) AS DECIMAL(18,2)) AS TicketPromedio
    FROM VW_Reportes_PedidosCompletados pc
    CROSS APPLY (
        SELECT CAST(CASE @Agrupacion
                        WHEN 'DIA'    THEN pc.FechaLocal
                        WHEN 'SEMANA' THEN DATEADD(DAY, (DATEDIFF(DAY, '19000101', pc.FechaLocal) / 7) * 7, '19000101')
                        ELSE DATEFROMPARTS(YEAR(pc.FechaLocal), MONTH(pc.FechaLocal), 1)
                    END AS DATE) AS Periodo
    ) x
    WHERE pc.FechaLocal BETWEEN @Desde AND @Hasta
    GROUP BY x.Periodo
    ORDER BY x.Periodo;
END;
GO

CREATE OR ALTER PROCEDURE SP_Reportes_VentasPorCategoria
    @IDUsuarioAccion INT,
    @Desde           DATE,
    @Hasta           DATE
AS
BEGIN
    SET NOCOUNT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    IF @Desde IS NULL OR @Hasta IS NULL OR @Hasta < @Desde
        THROW 50211, N'El rango de fechas no es válido.', 1;

    SELECT IDCategoria, NombreCategoria,
           SUM(UnidadesNetas) AS UnidadesVendidas,
           SUM(MontoNeto) AS TotalVendido
    FROM VW_Reportes_LineasVendidas
    WHERE FechaLocal BETWEEN @Desde AND @Hasta
    GROUP BY IDCategoria, NombreCategoria
    HAVING SUM(UnidadesNetas) > 0
    ORDER BY TotalVendido DESC, NombreCategoria;
END;
GO

CREATE OR ALTER PROCEDURE SP_Reportes_TopProductos
    @IDUsuarioAccion INT,
    @Desde           DATE,
    @Hasta           DATE,
    @Top             INT = 10
AS
BEGIN
    SET NOCOUNT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    IF @Desde IS NULL OR @Hasta IS NULL OR @Hasta < @Desde
        THROW 50211, N'El rango de fechas no es válido.', 1;
    IF @Top IS NULL OR @Top < 1 OR @Top > 100
        SET @Top = 10;

    SELECT TOP (@Top) IDProducto, NombreProducto,
           SUM(UnidadesNetas) AS UnidadesVendidas,
           SUM(MontoNeto) AS TotalVendido
    FROM VW_Reportes_LineasVendidas
    WHERE FechaLocal BETWEEN @Desde AND @Hasta
    GROUP BY IDProducto, NombreProducto
    HAVING SUM(UnidadesNetas) > 0
    ORDER BY SUM(UnidadesNetas) DESC, SUM(MontoNeto) DESC, NombreProducto;
END;
GO

-- Indicadores generales del periodo (incluye ticket promedio y carritos abandonados)
CREATE OR ALTER PROCEDURE SP_Reportes_Resumen
    @IDUsuarioAccion      INT,
    @Desde                DATE,
    @Hasta                DATE,
    @MinutosInactividad   INT = 1440
AS
BEGIN
    SET NOCOUNT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    IF @Desde IS NULL OR @Hasta IS NULL OR @Hasta < @Desde
        THROW 50211, N'El rango de fechas no es válido.', 1;
    IF @MinutosInactividad IS NULL OR @MinutosInactividad < 1
        SET @MinutosInactividad = 1440;

    SELECT COUNT(*) AS NumeroPedidos,
           ISNULL(SUM(TotalNeto), 0) AS TotalVendido,
           ISNULL(SUM(MontoDevuelto), 0) AS TotalDevuelto,
           CASE WHEN COUNT(*) = 0 THEN CAST(0 AS DECIMAL(18,2))
                ELSE CAST(ROUND(SUM(TotalNeto) / COUNT(*), 2) AS DECIMAL(18,2)) END AS TicketPromedio
    FROM VW_Reportes_PedidosCompletados
    WHERE FechaLocal BETWEEN @Desde AND @Hasta;

    SELECT COUNT(*) AS CarritosAbandonados
    FROM Carritos c
    WHERE c.Estado = 'ACTIVO'
      AND c.FechaUltimaActividad < DATEADD(MINUTE, -@MinutosInactividad, SYSUTCDATETIME())
      AND EXISTS (SELECT 1 FROM CarritoDetalle cd WHERE cd.IDCarrito = c.IDCarrito);
END;
GO

-- Carrito abandonado: activo, con productos y sin actividad durante @MinutosInactividad
CREATE OR ALTER PROCEDURE SP_Reportes_CarritosAbandonados
    @IDUsuarioAccion    INT,
    @MinutosInactividad INT = 1440,
    @Pagina             INT = 1,
    @TamanoPagina       INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    IF @MinutosInactividad IS NULL OR @MinutosInactividad < 1
        SET @MinutosInactividad = 1440;
    SET @Pagina = CASE WHEN @Pagina IS NULL OR @Pagina < 1 THEN 1 ELSE @Pagina END;
    SET @TamanoPagina = CASE WHEN @TamanoPagina IS NULL OR @TamanoPagina < 1 THEN 20
                             WHEN @TamanoPagina > 100 THEN 100 ELSE @TamanoPagina END;

    SELECT c.IDCarrito, u.NombreCompleto AS Cliente, u.Email, c.FechaUltimaActividad,
           t.Productos, t.ValorCarrito,
           COUNT(*) OVER() AS TotalRegistros
    FROM Carritos c
    LEFT JOIN Usuarios u ON u.IDUsuario = c.IDUsuario
    CROSS APPLY (
        SELECT SUM(cd.Cantidad) AS Productos,
               CAST(SUM(cd.Cantidad * v.Precio) AS DECIMAL(18,2)) AS ValorCarrito
        FROM CarritoDetalle cd
        JOIN VariantesProducto v ON v.IDVariante = cd.IDVariante
        WHERE cd.IDCarrito = c.IDCarrito
    ) t
    WHERE c.Estado = 'ACTIVO'
      AND t.Productos > 0
      AND c.FechaUltimaActividad < DATEADD(MINUTE, -@MinutosInactividad, SYSUTCDATETIME())
    ORDER BY c.FechaUltimaActividad
    OFFSET (@Pagina - 1) * @TamanoPagina ROWS FETCH NEXT @TamanoPagina ROWS ONLY;
END;
GO

------------------------------------------------------------------
-- Bitácora: consulta para Administradores, con filtro por módulo
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Bitacora_Listar
    @IDUsuarioAccion INT,
    @Modulo          VARCHAR(30) = NULL,
    @Desde           DATE = NULL,
    @Hasta           DATE = NULL,
    @Pagina          INT = 1,
    @TamanoPagina    INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    SET @Pagina = CASE WHEN @Pagina IS NULL OR @Pagina < 1 THEN 1 ELSE @Pagina END;
    SET @TamanoPagina = CASE WHEN @TamanoPagina IS NULL OR @TamanoPagina < 1 THEN 20
                             WHEN @TamanoPagina > 100 THEN 100 ELSE @TamanoPagina END;

    DECLARE @DesdeUTC DATETIME2(3) = NULL, @HastaUTC DATETIME2(3) = NULL;
    IF @Desde IS NOT NULL
        SET @DesdeUTC = CAST(CAST(@Desde AS DATETIME2(0)) AT TIME ZONE 'Central America Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));
    IF @Hasta IS NOT NULL
        SET @HastaUTC = CAST(CAST(DATEADD(DAY, 1, @Hasta) AS DATETIME2(0)) AT TIME ZONE 'Central America Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(3));

    SELECT b.IDBitacora, b.FechaHora, u.NombreCompleto AS Usuario, b.Modulo, b.Entidad, b.IDEntidad,
           b.Accion, b.ValorAnterior, b.ValorNuevo,
           COUNT(*) OVER() AS TotalRegistros
    FROM Bitacora b
    JOIN Usuarios u ON u.IDUsuario = b.IDUsuario
    WHERE (@Modulo IS NULL OR b.Modulo = @Modulo)
      AND (@DesdeUTC IS NULL OR b.FechaHora >= @DesdeUTC)
      AND (@HastaUTC IS NULL OR b.FechaHora < @HastaUTC)
    ORDER BY b.FechaHora DESC, b.IDBitacora DESC
    OFFSET (@Pagina - 1) * @TamanoPagina ROWS FETCH NEXT @TamanoPagina ROWS ONLY;
END;
GO

GO

-- ===== 014_Endurecimiento.sql =====
-- 014_Endurecimiento.sql
-- Defensas adicionales de la base de datos para que ni el backend ni una prueba agresiva
-- puedan dejar datos inconsistentes o provocar desbordamientos.

------------------------------------------------------------------
-- 1) Límites de rango (evitan desbordamientos de INT / DECIMAL antes de llegar a los cálculos)
------------------------------------------------------------------
ALTER TABLE CarritoDetalle
    ADD CONSTRAINT CK_CarritoDetalle_Maximo CHECK (Cantidad <= 1000);
ALTER TABLE PedidoDetalle
    ADD CONSTRAINT CK_PedidoDetalle_Maximo CHECK (Cantidad <= 1000);
ALTER TABLE ReservasExistencia
    ADD CONSTRAINT CK_Reservas_Maximo CHECK (Cantidad <= 1000);
ALTER TABLE VariantesProducto
    ADD CONSTRAINT CK_Variantes_Maximos CHECK (Precio <= 9999999.99 AND ExistenciaFisica <= 1000000);
ALTER TABLE MovimientosInventario
    ADD CONSTRAINT CK_Movimientos_Rango CHECK (Cantidad BETWEEN -1000000 AND 1000000);
ALTER TABLE Cupones
    ADD CONSTRAINT CK_Cupones_Maximos CHECK (Valor <= 9999999.99 AND MontoMinimo <= 9999999.99
                                             AND LimiteUsosTotal <= 100000000 AND LimiteUsosPorCliente <= 1000);
GO

------------------------------------------------------------------
-- 2) Una misma combinación de atributos no puede repetirse dentro de un producto
--    (los NULL se tratan como iguales: dos variantes sin talla ni color del mismo producto no caben)
------------------------------------------------------------------
CREATE UNIQUE INDEX UX_VariantesProducto_Atributos
    ON VariantesProducto (IDProducto, Talla, Color);
GO

------------------------------------------------------------------
-- 3) Trazabilidad: kardex, historial, pedidos, pagos y devoluciones no se modifican ni se eliminan
--    (las únicas actualizaciones permitidas, hechas por los SP, son estado de pago, estado de pedido y
--     CantidadDevuelta, que no pasan por estos triggers)
------------------------------------------------------------------
CREATE TRIGGER TR_MovimientosInventario_Inmutable
ON MovimientosInventario
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50003, N'El kardex no puede modificarse ni eliminarse.', 1;
END;
GO

CREATE TRIGGER TR_HistorialEstadosPedido_Inmutable
ON HistorialEstadosPedido
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50003, N'El historial de estados no puede modificarse ni eliminarse.', 1;
END;
GO

CREATE TRIGGER TR_Pedidos_NoEliminar
ON Pedidos
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50003, N'Los pedidos no se eliminan: se cancelan.', 1;
END;
GO

CREATE TRIGGER TR_PedidoDetalle_NoEliminar
ON PedidoDetalle
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50003, N'El detalle de un pedido no se elimina.', 1;
END;
GO

CREATE TRIGGER TR_Pagos_NoEliminar
ON Pagos
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50003, N'Los pagos no se eliminan.', 1;
END;
GO

CREATE TRIGGER TR_Devoluciones_NoEliminar
ON Devoluciones
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50003, N'Las devoluciones no se eliminan.', 1;
END;
GO

CREATE TRIGGER TR_UsosCupon_NoEliminar
ON UsosCupon
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50003, N'El registro de uso de un cupón no se elimina.', 1;
END;
GO

------------------------------------------------------------------
-- 4) Lectura sin bloqueos: el catálogo y los listados no esperan a una compra en curso
--    (READ_COMMITTED_SNAPSHOT). Los bloqueos explícitos del checkout siguen funcionando igual.
------------------------------------------------------------------
-- En un hosting compartido es posible que no haya permiso para cambiar opciones de la base:
-- en ese caso solo se avisa y todo lo demás funciona igual (con más esperas de lectura bajo carga).
BEGIN TRY
    DECLARE @Sql NVARCHAR(300) = N'ALTER DATABASE ' + QUOTENAME(DB_NAME()) + N' SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE';
    EXEC (@Sql);
END TRY
BEGIN CATCH
    PRINT CONCAT(N'AVISO: no se pudo activar READ_COMMITTED_SNAPSHOT (', ERROR_MESSAGE(), N'). Continúa sin esa opción.');
END CATCH;
GO

GO


GO

-- ============ 016_Direcciones_Estados ============
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

GO

SET NOEXEC OFF;
GO

SELECT Email, NombreRol = (SELECT NombreRol FROM Roles r WHERE r.IDRol = u.IDRol), Activo FROM Usuarios u ORDER BY IDUsuario;
GO

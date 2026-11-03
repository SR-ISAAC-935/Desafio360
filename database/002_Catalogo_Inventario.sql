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

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

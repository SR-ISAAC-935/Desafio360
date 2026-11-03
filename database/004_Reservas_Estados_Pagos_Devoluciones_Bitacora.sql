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

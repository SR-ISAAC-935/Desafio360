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

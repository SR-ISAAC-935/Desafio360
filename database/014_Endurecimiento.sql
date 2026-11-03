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

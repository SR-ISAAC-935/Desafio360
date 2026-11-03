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

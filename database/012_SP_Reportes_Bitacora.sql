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

-- 013_Pruebas.sql
-- Pruebas de humo, de casos negativos y de integridad de los procedimientos almacenados.
--
-- CÓMO USARLO
--  * Ejecutar UNA vez sobre la base recién creada y sembrada (scripts 001 a 012, 014 y 016).
--    Las pruebas escriben datos (pedidos, ajustes, devoluciones). Para repetirlas, recrear la base.
--  * Los procedimientos devuelven conjuntos de resultados; para leer el informe cómodamente
--    active en SSMS "Resultados en texto" o mire la pestaña Mensajes: al final se imprime cada
--    caso que falló y el resumen.
--  * "esperado" es el número de error del THROW (50xxx) o 0 si la operación debe funcionar.
--    547 = violación de CHECK/FK, 2601/2627 = duplicado en índice único.
--  * La prueba real de concurrencia (dos sesiones a la vez) está explicada al final del archivo.

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#R') IS NOT NULL DROP TABLE #R;
CREATE TABLE #R (Orden INT IDENTITY(1,1), Prueba NVARCHAR(200), Resultado VARCHAR(5), Detalle NVARCHAR(600));
IF OBJECT_ID('tempdb..#C') IS NOT NULL DROP TABLE #C;
CREATE TABLE #C (IDCarrito INT, IDUsuario INT, TokenInvitado UNIQUEIDENTIFIER, Estado VARCHAR(15), FechaUltimaActividad DATETIME2(0));
IF OBJECT_ID('tempdb..#K') IS NOT NULL DROP TABLE #K;
CREATE TABLE #K (IDVariante INT, SKU VARCHAR(50), ExistenciaFisica INT, SumaKardex INT);
GO

IF OBJECT_ID('tempdb..#Probar') IS NOT NULL DROP PROCEDURE #Probar;
GO
-- Ejecuta una instrucción y compara el número de error obtenido con el esperado (0 = sin error)
CREATE PROCEDURE #Probar
    @Nombre         NVARCHAR(200),
    @Sql            NVARCHAR(MAX),
    @ErrorEsperado  INT = 0
AS
BEGIN
    DECLARE @Err INT = 0, @Msg NVARCHAR(500) = N'';
    BEGIN TRY
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @Err = ERROR_NUMBER();
        SET @Msg = LEFT(ERROR_MESSAGE(), 400);
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    END CATCH;

    INSERT INTO #R (Prueba, Resultado, Detalle)
    VALUES (@Nombre,
            CASE WHEN @Err = @ErrorEsperado THEN 'OK' ELSE 'FALLA' END,
            CASE WHEN @Err = @ErrorEsperado THEN NULL
                 ELSE CONCAT(N'esperado=', @ErrorEsperado, N' obtenido=', @Err, N' ', @Msg) END);
END;
GO

IF OBJECT_ID('tempdb..#Verificar') IS NOT NULL DROP PROCEDURE #Verificar;
GO
-- Registra el resultado de una verificación hecha con una consulta
CREATE PROCEDURE #Verificar
    @Nombre  NVARCHAR(200),
    @Ok      BIT,
    @Detalle NVARCHAR(500) = NULL
AS
BEGIN
    INSERT INTO #R (Prueba, Resultado, Detalle)
    VALUES (@Nombre, CASE WHEN @Ok = 1 THEN 'OK' ELSE 'FALLA' END, CASE WHEN @Ok = 1 THEN NULL ELSE @Detalle END);
END;
GO

IF OBJECT_ID('tempdb..#Resumen') IS NOT NULL DROP PROCEDURE #Resumen;
GO
-- Imprime las pruebas con falla y el total
CREATE PROCEDURE #Resumen
AS
BEGIN
    DECLARE @Total INT = (SELECT COUNT(*) FROM #R);
    DECLARE @Fallas INT = (SELECT COUNT(*) FROM #R WHERE Resultado = 'FALLA');
    DECLARE @Linea NVARCHAR(800);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT CONCAT(N'FALLA | ', Prueba, N' | ', Detalle) FROM #R WHERE Resultado = 'FALLA' ORDER BY Orden;
    OPEN cur;
    FETCH NEXT FROM cur INTO @Linea;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        PRINT @Linea;
        FETCH NEXT FROM cur INTO @Linea;
    END;
    CLOSE cur;
    DEALLOCATE cur;

    PRINT CONCAT(N'==== ', @Total - @Fallas, N' de ', @Total, N' pruebas OK; ', @Fallas, N' con falla ====');
    SELECT Orden, Resultado, Prueba, Detalle FROM #R ORDER BY CASE Resultado WHEN 'FALLA' THEN 0 ELSE 1 END, Orden;
END;
GO

------------------------------------------------------------------
-- LOTE PRINCIPAL
------------------------------------------------------------------
DECLARE @Admin INT = (SELECT IDUsuario FROM Usuarios WHERE Email = N'admin@shopcart.test');
DECLARE @Op    INT = (SELECT IDUsuario FROM Usuarios WHERE Email = N'operador@shopcart.test');
DECLARE @Cli   INT = (SELECT IDUsuario FROM Usuarios WHERE Email = N'cliente@shopcart.test');
DECLARE @Dir   INT = (SELECT TOP (1) IDDireccion FROM Direcciones WHERE IDUsuario = @Cli);
DECLARE @VPoloMAz INT = (SELECT IDVariante FROM VariantesProducto WHERE SKU = 'POLO-M-AZ');
DECLARE @VPoloLBl INT = (SELECT IDVariante FROM VariantesProducto WHERE SKU = 'POLO-L-BL');
DECLARE @VGorraNg INT = (SELECT IDVariante FROM VariantesProducto WHERE SKU = 'GOR-U-NG');
DECLARE @VGorraRj INT = (SELECT IDVariante FROM VariantesProducto WHERE SKU = 'GOR-U-RJ');
DECLARE @VJean30  INT = (SELECT IDVariante FROM VariantesProducto WHERE SKU = 'JEAN-30-AZ');
DECLARE @Cat   INT = (SELECT TOP (1) IDCategoria FROM Categorias ORDER BY IDCategoria);

IF @Admin IS NULL OR @Op IS NULL OR @Cli IS NULL OR @Dir IS NULL OR @VPoloMAz IS NULL OR @VGorraRj IS NULL
BEGIN
    PRINT N'Ejecute primero los scripts 001 a 012, 014 y 016 (y las semillas) en una base nueva.';
    RETURN;
END;

DECLARE @S NVARCHAR(MAX), @Ok BIT, @Det NVARCHAR(500), @N INT, @N2 INT, @Dec DECIMAL(18,2), @Dec2 DECIMAL(18,2);
DECLARE @Otro INT, @DirOp INT, @DirOtro INT;
DECLARE @CartCli INT, @CartAdmin INT, @CartOp INT, @CartOtro INT, @CartG2 INT, @CartCli2 INT, @CartCli3 INT, @CartCli4 INT;
DECLARE @Tok2 UNIQUEIDENTIFIER;
DECLARE @P1 INT, @P2 INT, @P3 INT, @L1 INT, @L2 INT, @L3 INT;
DECLARE @StockAntes INT, @StockDespues INT, @UsosAntes INT, @IDRopa15 INT;

------------------------------------------------------------------
-- A. ACCESO Y PERMISOS
------------------------------------------------------------------
SET @S = CONCAT(N'EXEC SP_Categorias_Crear @NombreCategoria = N''QA Cliente'', @IDUsuarioAccion = ', @Cli);
EXEC #Probar N'A01 Un cliente no puede crear categorías', @S, 50103;

SET @S = CONCAT(N'EXEC SP_Variantes_CambiarPrecio @IDVariante = ', @VPoloMAz, N', @PrecioNuevo = 10, @IDUsuarioAccion = ', @Op);
EXEC #Probar N'A02 Un operador no puede cambiar precios', @S, 50103;

EXEC #Probar N'A03 Registro con correo duplicado (sin distinguir mayúsculas)',
     N'EXEC SP_Auth_RegistrarCliente @Email = N''CLIENTE@shopcart.test'', @NombreCompleto = N''Duplicado'', @PasswordHash = ''x''', 50101;

EXEC #Probar N'A04 Registro válido de un segundo cliente',
     N'EXEC SP_Auth_RegistrarCliente @Email = N''otro@shopcart.test'', @NombreCompleto = N''Otro Cliente'', @PasswordHash = ''hash-de-prueba''', 0;
SET @Otro = (SELECT IDUsuario FROM Usuarios WHERE Email = N'otro@shopcart.test');

SET @S = CONCAT(N'EXEC SP_Usuarios_CambiarEstado @IDUsuario = ', @Admin, N', @Activo = 0, @IDUsuarioAccion = ', @Admin);
EXEC #Probar N'A05 El administrador no puede desactivarse a sí mismo', @S, 50105;

SET @S = CONCAT(N'EXEC SP_Usuarios_CambiarEstado @IDUsuario = ', @Cli, N', @Activo = 0, @IDUsuarioAccion = ', @Cli);
EXEC #Probar N'A06 Un cliente no puede desactivar usuarios', @S, 50103;

-- Refresh tokens: rotación y detección de reuso
SET @S = CONCAT(N'EXEC SP_Auth_GuardarRefreshToken @IDUsuario = ', @Cli, N', @TokenHash = ''', REPLICATE('a', 64), N''', @FechaExpiracion = ''2099-01-01''');
EXEC #Probar N'A07 Guardar refresh token', @S, 0;

SET @S = CONCAT(N'EXEC SP_Auth_RotarRefreshToken @TokenHashActual = ''', REPLICATE('a', 64), N''', @TokenHashNuevo = ''', REPLICATE('b', 64), N''', @FechaExpiracionNueva = ''2099-01-01''');
EXEC #Probar N'A08 Rotar refresh token válido', @S, 0;

SET @S = CONCAT(N'EXEC SP_Auth_RotarRefreshToken @TokenHashActual = ''', REPLICATE('a', 64), N''', @TokenHashNuevo = ''', REPLICATE('c', 64), N''', @FechaExpiracionNueva = ''2099-01-01''');
EXEC #Probar N'A09 Reusar un token ya rotado se detecta', @S, 50112;

SET @S = CONCAT(N'EXEC SP_Auth_RotarRefreshToken @TokenHashActual = ''', REPLICATE('b', 64), N''', @TokenHashNuevo = ''', REPLICATE('d', 64), N''', @FechaExpiracionNueva = ''2099-01-01''');
EXEC #Probar N'A10 Tras detectar reuso quedan revocadas todas las sesiones', @S, 50112;

SET @S = CONCAT(N'EXEC SP_Auth_RotarRefreshToken @TokenHashActual = ''', REPLICATE('z', 64), N''', @TokenHashNuevo = ''', REPLICATE('e', 64), N''', @FechaExpiracionNueva = ''2099-01-01''');
EXEC #Probar N'A11 Refresh token inexistente', @S, 50111;

-- Direcciones de apoyo para las pruebas de checkout
INSERT INTO Direcciones (IDUsuario, Direccion, Municipio, Departamento) VALUES (@Op, N'Dirección QA operador', N'Guatemala', N'Guatemala');
INSERT INTO Direcciones (IDUsuario, Direccion, Municipio, Departamento) VALUES (@Otro, N'Dirección QA otro cliente', N'Guatemala', N'Guatemala');
SET @DirOp = (SELECT TOP (1) IDDireccion FROM Direcciones WHERE IDUsuario = @Op);
SET @DirOtro = (SELECT TOP (1) IDDireccion FROM Direcciones WHERE IDUsuario = @Otro);

------------------------------------------------------------------
-- B. CATÁLOGO
------------------------------------------------------------------
SET @S = CONCAT(N'EXEC SP_Categorias_Crear @NombreCategoria = N''Ropa'', @IDUsuarioAccion = ', @Admin);
EXEC #Probar N'B01 Categoría duplicada', @S, 50121;

SET @S = CONCAT(N'DECLARE @V TT_Catalogo_Variantes; EXEC SP_Productos_Crear @NombreProducto = N''Sin variantes'', @IDCategoria = ', @Cat,
                N', @Variantes = @V, @IDUsuarioAccion = ', @Admin);
EXEC #Probar N'B02 Producto sin variantes se rechaza', @S, 50125;

SET @S = CONCAT(N'DECLARE @V TT_Catalogo_Variantes; INSERT INTO @V (SKU, Precio, ExistenciaInicial) VALUES (''POLO-M-AZ'', 10, 1); ',
                N'EXEC SP_Productos_Crear @NombreProducto = N''SKU repetido'', @IDCategoria = ', @Cat, N', @Variantes = @V, @IDUsuarioAccion = ', @Admin);
EXEC #Probar N'B03 SKU duplicado se rechaza', @S, 50121;

SET @S = CONCAT(N'DECLARE @V TT_Catalogo_Variantes; INSERT INTO @V (SKU, Talla, Color, Precio, ExistenciaInicial) VALUES (''QA-1'', N''M'', N''Rojo'', 99.50, 5), (''QA-2'', N''L'', N''Rojo'', 109.90, 0); ',
                N'EXEC SP_Productos_Crear @NombreProducto = N''Producto QA'', @IDCategoria = ', @Cat, N', @Variantes = @V, @IDUsuarioAccion = ', @Admin);
EXEC #Probar N'B04 Producto con variantes (TVP) se crea', @S, 0;

SET @S = CONCAT(N'EXEC SP_Variantes_CambiarPrecio @IDVariante = ', @VPoloMAz, N', @PrecioNuevo = -5, @IDUsuarioAccion = ', @Admin);
EXEC #Probar N'B05 Precio negativo se rechaza', @S, 50126;

SET @S = CONCAT(N'EXEC SP_Variantes_Crear @IDProducto = 1, @SKU = ''QA-NEG'', @Precio = -1, @IDUsuarioAccion = ', @Admin);
EXEC #Probar N'B06 Variante con precio negativo se rechaza', @S, 50126;

SET @S = CONCAT(N'EXEC SP_Variantes_CambiarPrecio @IDVariante = 99999999, @PrecioNuevo = 5, @IDUsuarioAccion = ', @Admin);
EXEC #Probar N'B07 Cambiar precio de variante inexistente', @S, 50124;

SET @S = CONCAT(N'EXEC SP_Productos_Actualizar @IDProducto = 99999999, @NombreProducto = N''X'', @IDCategoria = ', @Cat, N', @Activo = 1, @IDUsuarioAccion = ', @Admin);
EXEC #Probar N'B08 Actualizar producto inexistente', @S, 50123;

-- Búsqueda: comodines, texto con comilla, parámetros extremos
EXEC #Probar N'B10 Búsqueda con comodín %', N'EXEC SP_Catalogo_Buscar @Texto = N''%''', 0;
EXEC #Probar N'B11 Búsqueda con comodín _', N'EXEC SP_Catalogo_Buscar @Texto = N''_''', 0;
EXEC #Probar N'B12 Búsqueda con corchete [', N'EXEC SP_Catalogo_Buscar @Texto = N''[a''', 0;
SET @S = CONCAT(N'EXEC SP_Catalogo_Buscar @Texto = N', NCHAR(39), NCHAR(39), NCHAR(39), N' OR 1=1 --', NCHAR(39));
EXEC #Probar N'B13 Búsqueda con intento de inyección SQL', @S, 0;
EXEC #Probar N'B14 Página 0 y tamaño enorme se normalizan', N'EXEC SP_Catalogo_Buscar @Pagina = 0, @TamanoPagina = 100000', 0;
EXEC #Probar N'B15 Página negativa y tamaño negativo', N'EXEC SP_Catalogo_Buscar @Pagina = -5, @TamanoPagina = -1', 0;
EXEC #Probar N'B16 Orden inválido se ignora', N'EXEC SP_Catalogo_Buscar @Ordenar = ''NO_EXISTE''', 0;
EXEC #Probar N'B17 Rango de precio invertido', N'EXEC SP_Catalogo_Buscar @PrecioMin = 500, @PrecioMax = 1', 0;
EXEC #Probar N'B18 Solo disponibles con filtros', N'EXEC SP_Catalogo_Buscar @SoloDisponibles = 1, @Ordenar = ''PRECIO_DESC''', 0;
EXEC #Probar N'B19 Detalle de producto inexistente no falla', N'EXEC SP_Catalogo_ObtenerProducto @IDProducto = 99999999', 0;

------------------------------------------------------------------
-- C. INVENTARIO
------------------------------------------------------------------
SET @S = CONCAT(N'EXEC SP_Inventario_AjustarExistencia @IDVariante = ', @VGorraNg, N', @TipoMovimiento = ''AJUSTE'', @Cantidad = -1, @Motivo = N'''', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'C01 Ajuste sin motivo', @S, 50133;

SET @S = CONCAT(N'EXEC SP_Inventario_AjustarExistencia @IDVariante = ', @VGorraNg, N', @TipoMovimiento = ''AJUSTE'', @Cantidad = -100000, @Motivo = N''prueba'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'C02 Ajuste que deja la existencia negativa', @S, 50131;

SET @S = CONCAT(N'EXEC SP_Inventario_AjustarExistencia @IDVariante = ', @VGorraNg, N', @TipoMovimiento = ''ENTRADA'', @Cantidad = -5, @Motivo = N''prueba'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'C03 Entrada con cantidad negativa', @S, 50135;

SET @S = CONCAT(N'EXEC SP_Inventario_AjustarExistencia @IDVariante = ', @VGorraNg, N', @TipoMovimiento = ''SALIDA'', @Cantidad = -5, @Motivo = N''prueba'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'C04 Tipo de movimiento SALIDA no se permite manualmente', @S, 50134;

SET @S = CONCAT(N'EXEC SP_Inventario_AjustarExistencia @IDVariante = ', @VGorraNg, N', @TipoMovimiento = ''AJUSTE'', @Cantidad = 0, @Motivo = N''prueba'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'C05 Ajuste con cantidad cero', @S, 50135;

SET @S = CONCAT(N'EXEC SP_Inventario_AjustarExistencia @IDVariante = 99999999, @TipoMovimiento = ''AJUSTE'', @Cantidad = 1, @Motivo = N''prueba'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'C06 Ajuste de variante inexistente', @S, 50124;

SET @S = CONCAT(N'EXEC SP_Inventario_AjustarExistencia @IDVariante = ', @VGorraNg, N', @TipoMovimiento = ''AJUSTE'', @Cantidad = 1, @Motivo = N''prueba'', @IDUsuarioAccion = ', @Cli);
EXEC #Probar N'C07 Un cliente no puede ajustar inventario', @S, 50103;

SET @S = CONCAT(N'EXEC SP_Inventario_AjustarExistencia @IDVariante = ', @VGorraNg, N', @TipoMovimiento = ''AJUSTE'', @Cantidad = 5, @Motivo = N''Conteo físico'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'C08 Ajuste positivo válido', @S, 0;
SET @S = CONCAT(N'EXEC SP_Inventario_AjustarExistencia @IDVariante = ', @VGorraNg, N', @TipoMovimiento = ''AJUSTE'', @Cantidad = -5, @Motivo = N''Conteo físico'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'C09 Ajuste negativo válido', @S, 0;

-- Límite del tipo INT: el backend debe impedir cantidades así de grandes (ver README)
SET @S = CONCAT(N'EXEC SP_Inventario_AjustarExistencia @IDVariante = ', @VGorraNg, N', @TipoMovimiento = ''ENTRADA'', @Cantidad = 2147483647, @Motivo = N''desborde'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'C10 Cantidad fuera de rango (más de 1,000,000) se rechaza', @S, 50135;

SET @S = CONCAT(N'DECLARE @E TT_Inventario_Entradas; INSERT INTO @E VALUES (', @VGorraNg, N', 10), (', @VGorraRj, N', 10); ',
                N'EXEC SP_Inventario_RegistrarEntradas @Entradas = @E, @Motivo = N''Compra a proveedor'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'C11 Entradas masivas (TVP) válidas', @S, 0;

SET @S = CONCAT(N'DECLARE @E TT_Inventario_Entradas; INSERT INTO @E VALUES (99999999, 10); ',
                N'EXEC SP_Inventario_RegistrarEntradas @Entradas = @E, @Motivo = N''Compra'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'C12 Entradas masivas con variante inexistente', @S, 50124;

SET @S = CONCAT(N'DECLARE @E TT_Inventario_Entradas; EXEC SP_Inventario_RegistrarEntradas @Entradas = @E, @Motivo = N''Compra'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'C13 Entradas masivas vacías', @S, 50135;

SET @S = CONCAT(N'DECLARE @E TT_Inventario_Entradas; INSERT INTO @E VALUES (', @VGorraNg, N', 1); EXEC SP_Inventario_RegistrarEntradas @Entradas = @E, @Motivo = N'''', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'C14 Entradas masivas sin motivo', @S, 50133;

SET @S = CONCAT(N'DECLARE @E TT_Inventario_Entradas; INSERT INTO @E VALUES (', @VGorraNg, N', 1); EXEC SP_Inventario_RegistrarEntradas @Entradas = @E, @Motivo = N''x'', @IDUsuarioAccion = ', @Cli);
EXEC #Probar N'C15 Un cliente no puede registrar entradas', @S, 50103;

SET @S = CONCAT(N'EXEC SP_Inventario_ConsultarKardex @IDVariante = ', @VGorraNg, N', @IDUsuarioAccion = ', @Cli);
EXEC #Probar N'C16 Un cliente no puede consultar el kardex', @S, 50103;
SET @S = CONCAT(N'EXEC SP_Inventario_ConsultarKardex @IDVariante = ', @VGorraNg, N', @IDUsuarioAccion = ', @Op, N', @Pagina = 0, @TamanoPagina = 9999');
EXEC #Probar N'C17 Kardex con paginación extrema', @S, 0;

DELETE FROM #K;
INSERT INTO #K EXEC SP_Inventario_VerificarKardex;
SET @N = (SELECT COUNT(*) FROM #K);
SET @Ok = CASE WHEN @N = 0 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'variantes con diferencia: ', @N);
EXEC #Verificar N'C18 Existencia = suma del kardex (tras ajustes y entradas)', @Ok, @Det;

------------------------------------------------------------------
-- D. CARRITO
------------------------------------------------------------------
DELETE FROM #C; INSERT INTO #C EXEC SP_Carrito_ObtenerOCrear @IDUsuario = @Cli;
SET @CartCli = (SELECT TOP (1) IDCarrito FROM #C);
DELETE FROM #C; INSERT INTO #C EXEC SP_Carrito_ObtenerOCrear @IDUsuario = @Admin;
SET @CartAdmin = (SELECT TOP (1) IDCarrito FROM #C);
DELETE FROM #C; INSERT INTO #C EXEC SP_Carrito_ObtenerOCrear @IDUsuario = @Op;
SET @CartOp = (SELECT TOP (1) IDCarrito FROM #C);
DELETE FROM #C; INSERT INTO #C EXEC SP_Carrito_ObtenerOCrear;
SET @CartOtro = (SELECT TOP (1) IDCarrito FROM #C);          -- carrito de invitado (luego pasa a "Otro")
DECLARE @TokOtro UNIQUEIDENTIFIER = (SELECT TOP (1) TokenInvitado FROM #C);

SET @Ok = CASE WHEN @CartCli IS NOT NULL AND @CartAdmin IS NOT NULL AND @CartOp IS NOT NULL AND @CartOtro IS NOT NULL AND @TokOtro IS NOT NULL THEN 1 ELSE 0 END;
EXEC #Verificar N'D00 Se crean carritos de usuario e invitado', @Ok, N'no se pudo crear algún carrito';

DELETE FROM #C; INSERT INTO #C EXEC SP_Carrito_ObtenerOCrear @IDUsuario = @Cli;
SET @Ok = CASE WHEN (SELECT TOP (1) IDCarrito FROM #C) = @CartCli THEN 1 ELSE 0 END;
EXEC #Verificar N'D01 Obtener el carrito activo no crea uno nuevo', @Ok, N'devolvió un carrito distinto';

SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartCli, N', @IDVariante = ', @VGorraNg, N', @Cantidad = 0, @IDUsuario = ', @Cli);
EXEC #Probar N'D02 Agregar cantidad cero', @S, 50147;
SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartCli, N', @IDVariante = ', @VGorraNg, N', @Cantidad = -3, @IDUsuario = ', @Cli);
EXEC #Probar N'D03 Agregar cantidad negativa', @S, 50147;
SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartCli, N', @IDVariante = 99999999, @Cantidad = 1, @IDUsuario = ', @Cli);
EXEC #Probar N'D04 Agregar variante inexistente', @S, 50143;
SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartCli, N', @IDVariante = ', @VPoloLBl, N', @Cantidad = 2, @IDUsuario = ', @Cli);
EXEC #Probar N'D05 Agregar más de la existencia disponible', @S, 50144;
SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartCli, N', @IDVariante = ', @VGorraNg, N', @Cantidad = 2147483647, @IDUsuario = ', @Cli);
EXEC #Probar N'D06 Cantidad mayor a 1000 por producto se rechaza', @S, 50147;
SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartAdmin, N', @IDVariante = ', @VGorraNg, N', @Cantidad = 1, @IDUsuario = ', @Cli);
EXEC #Probar N'D07 Un cliente no puede usar el carrito de otro usuario', @S, 50142;
SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartOtro, N', @IDVariante = ', @VGorraNg, N', @Cantidad = 1, @TokenInvitado = ''', NEWID(), N'''');
EXEC #Probar N'D08 Token de invitado ajeno', @S, 50142;
SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = 99999999, @IDVariante = ', @VGorraNg, N', @Cantidad = 1, @IDUsuario = ', @Cli);
EXEC #Probar N'D09 Carrito inexistente', @S, 50141;
SET @S = CONCAT(N'EXEC SP_Carrito_Resumen @IDCarrito = ', @CartAdmin, N', @IDUsuario = ', @Cli);
EXEC #Probar N'D10 Resumen de un carrito ajeno', @S, 50142;

SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartCli, N', @IDVariante = ', @VGorraNg, N', @Cantidad = 1, @IDUsuario = ', @Cli);
EXEC #Probar N'D11 Agregar producto válido', @S, 0;
SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartCli, N', @IDVariante = ', @VGorraNg, N', @Cantidad = 2147483647, @IDUsuario = ', @Cli);
EXEC #Probar N'D11b Cantidad gigante sobre una línea existente se rechaza', @S, 50147;
SET @S = CONCAT(N'EXEC SP_Carrito_ActualizarCantidad @IDCarrito = ', @CartCli, N', @IDVariante = ', @VPoloMAz, N', @Cantidad = 1, @IDUsuario = ', @Cli);
EXEC #Probar N'D12 Actualizar una línea que no existe', @S, 50146;
SET @S = CONCAT(N'EXEC SP_Carrito_EliminarProducto @IDCarrito = ', @CartCli, N', @IDVariante = ', @VPoloMAz, N', @IDUsuario = ', @Cli);
EXEC #Probar N'D13 Eliminar una línea que no existe', @S, 50146;
SET @S = CONCAT(N'EXEC SP_Carrito_ActualizarCantidad @IDCarrito = ', @CartCli, N', @IDVariante = ', @VGorraNg, N', @Cantidad = 0, @IDUsuario = ', @Cli);
EXEC #Probar N'D14 Actualizar a cantidad cero', @S, 50147;

-- Cupones al aplicar
SET @S = CONCAT(N'EXEC SP_Carrito_AplicarCupon @IDCarrito = ', @CartCli, N', @IDUsuario = ', @Cli, N', @Codigo = ''BIENVENIDO10''');
EXEC #Probar N'D20 Cupón con monto mínimo no alcanzado', @S, 50156;
SET @S = CONCAT(N'EXEC SP_Carrito_AplicarCupon @IDCarrito = ', @CartCli, N', @IDUsuario = ', @Cli, N', @Codigo = ''ROPA15''');
EXEC #Probar N'D21 Cupón de categoría sin productos de esa categoría', @S, 50158;
SET @S = CONCAT(N'EXEC SP_Carrito_AplicarCupon @IDCarrito = ', @CartCli, N', @IDUsuario = ', @Cli, N', @Codigo = ''VENCIDO5''');
EXEC #Probar N'D22 Cupón vencido', @S, 50154;
SET @S = CONCAT(N'EXEC SP_Carrito_AplicarCupon @IDCarrito = ', @CartCli, N', @IDUsuario = ', @Cli, N', @Codigo = ''AGOTADO20''');
EXEC #Probar N'D23 Cupón agotado', @S, 50155;
SET @S = CONCAT(N'EXEC SP_Carrito_AplicarCupon @IDCarrito = ', @CartCli, N', @IDUsuario = ', @Cli, N', @Codigo = ''NOEXISTE''');
EXEC #Probar N'D24 Cupón inexistente', @S, 50151;
SET @S = CONCAT(N'EXEC SP_Carrito_AplicarCupon @IDCarrito = ', @CartOtro, N', @Codigo = ''BIENVENIDO10''');
EXEC #Probar N'D25 Un invitado debe iniciar sesión para usar cupones', @S, 50159;

SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartCli, N', @IDVariante = ', @VPoloMAz, N', @Cantidad = 2, @IDUsuario = ', @Cli);
EXEC #Probar N'D26 Agregar polos al carrito del cliente', @S, 0;
SET @S = CONCAT(N'EXEC SP_Carrito_AplicarCupon @IDCarrito = ', @CartCli, N', @IDUsuario = ', @Cli, N', @Codigo = ''ENVIO25''');
EXEC #Probar N'D27 Aplicar un cupón válido', @S, 0;
SET @S = CONCAT(N'EXEC SP_Carrito_AplicarCupon @IDCarrito = ', @CartCli, N', @IDUsuario = ', @Cli, N', @Codigo = ''ROPA15''');
EXEC #Probar N'D28 Aplicar otro cupón reemplaza al anterior (uno por pedido)', @S, 0;

SET @IDRopa15 = (SELECT IDCupon FROM Cupones WHERE Codigo = 'ROPA15');
SET @Ok = CASE WHEN (SELECT IDCupon FROM Carritos WHERE IDCarrito = @CartCli) = @IDRopa15 THEN 1 ELSE 0 END;
EXEC #Verificar N'D29 El carrito conserva un solo cupón (el último)', @Ok, N'el carrito no quedó con ROPA15';

SELECT @Dec = Descuento FROM FU_Cupones_CalculoDescuento(@IDRopa15, @CartCli);
SET @Ok = CASE WHEN @Dec = 44.70 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'descuento calculado=', @Dec, N' esperado=44.70');
EXEC #Verificar N'D30 Descuento del 15 % solo sobre la categoría (2 x Q149)', @Ok, @Det;

-- Fusión de carritos
DELETE FROM #C; INSERT INTO #C EXEC SP_Carrito_ObtenerOCrear;
SET @CartG2 = (SELECT TOP (1) IDCarrito FROM #C);
SET @Tok2 = (SELECT TOP (1) TokenInvitado FROM #C);
SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartG2, N', @IDVariante = ', @VGorraNg, N', @Cantidad = 1, @TokenInvitado = ''', @Tok2, N'''');
EXEC #Probar N'D31 Invitado agrega un producto', @S, 0;
SET @S = CONCAT(N'EXEC SP_Carrito_Fusionar @TokenInvitado = ''', @Tok2, N''', @IDUsuario = ', @Cli);
EXEC #Probar N'D32 Fusionar carrito de invitado con el del cliente', @S, 0;
SET @N = (SELECT Cantidad FROM CarritoDetalle WHERE IDCarrito = @CartCli AND IDVariante = @VGorraNg);
SET @Ok = CASE WHEN @N = 2 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'cantidad de gorras tras fusionar=', @N, N' esperado=2');
EXEC #Verificar N'D33 La fusión suma las cantidades de la misma variante', @Ok, @Det;

SET @S = CONCAT(N'EXEC SP_Carrito_Fusionar @TokenInvitado = ''', @TokOtro, N''', @IDUsuario = ', @Otro);
EXEC #Probar N'D34 El invitado sin carrito previo hereda su carrito al iniciar sesión', @S, 0;
SET @Ok = CASE WHEN (SELECT IDUsuario FROM Carritos WHERE IDCarrito = @CartOtro) = @Otro
                AND (SELECT TokenInvitado FROM Carritos WHERE IDCarrito = @CartOtro) IS NULL THEN 1 ELSE 0 END;
EXEC #Verificar N'D35 El carrito de invitado pasó al usuario', @Ok, N'el carrito no cambió de dueño';

------------------------------------------------------------------
-- E. CHECKOUT: última unidad, reserva, precio y pedido idempotente
------------------------------------------------------------------
-- Última unidad: Operador y "Otro" tienen la última POLO-L-BL en su carrito; solo uno puede reservarla
SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartOp, N', @IDVariante = ', @VPoloLBl, N', @Cantidad = 1, @IDUsuario = ', @Op);
EXEC #Probar N'E01 Primer cliente agrega la última unidad', @S, 0;
SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartOtro, N', @IDVariante = ', @VPoloLBl, N', @Cantidad = 1, @IDUsuario = ', @Otro);
EXEC #Probar N'E02 Segundo cliente también la agrega (aún no está reservada)', @S, 0;

SET @S = CONCAT(N'EXEC SP_Inventario_ReservarExistencia @IDCarrito = ', @CartOp, N', @IDUsuario = ', @Op);
EXEC #Probar N'E03 El primero en iniciar el pago reserva la última unidad', @S, 0;
SET @S = CONCAT(N'EXEC SP_Inventario_ReservarExistencia @IDCarrito = ', @CartOtro, N', @IDUsuario = ', @Otro);
EXEC #Probar N'E04 El segundo recibe un mensaje claro: no hay sobreventa', @S, 50172;

SET @N = (SELECT Disponible FROM FU_Inventario_Disponibilidad(NULL) WHERE IDVariante = @VPoloLBl);
SET @Ok = CASE WHEN @N = 0 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'disponible=', @N, N' esperado=0');
EXEC #Verificar N'E05 La disponibilidad de la última unidad es 0 mientras está reservada', @Ok, @Det;

-- Vence la reserva del operador (se simula adelantando sus fechas una hora)
UPDATE ReservasExistencia
SET FechaCreacion = DATEADD(MINUTE, -60, FechaCreacion), FechaVencimiento = DATEADD(MINUTE, -45, FechaVencimiento)
WHERE IDCarrito = @CartOp AND Estado = 'ACTIVA';

SET @N = (SELECT Disponible FROM FU_Inventario_Disponibilidad(NULL) WHERE IDVariante = @VPoloLBl);
SET @Ok = CASE WHEN @N = 1 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'disponible=', @N, N' esperado=1');
EXEC #Verificar N'E06 Una reserva vencida libera la existencia sin intervención manual', @Ok, @Det;

SET @S = CONCAT(N'EXEC SP_Pedidos_CrearPedido @IDUsuario = ', @Op, N', @IDCarrito = ', @CartOp, N', @IDDireccion = ', @DirOp, N', @LlaveIdempotencia = ''LLAVE-QA-VENCIDA''');
EXEC #Probar N'E07 No se puede pagar con la reserva vencida', @S, 50174;

SET @S = CONCAT(N'EXEC SP_Inventario_ReservarExistencia @IDCarrito = ', @CartOtro, N', @IDUsuario = ', @Otro);
EXEC #Probar N'E08 Ahora el otro cliente sí puede reservar la unidad', @S, 0;

-- Validaciones del pedido
SET @S = CONCAT(N'EXEC SP_Inventario_ReservarExistencia @IDCarrito = ', @CartAdmin, N', @IDUsuario = ', @Admin);
EXEC #Probar N'E09 Reservar con el carrito vacío', @S, 50173;
SET @S = CONCAT(N'EXEC SP_Pedidos_CrearPedido @IDUsuario = ', @Admin, N', @IDCarrito = ', @CartAdmin, N', @IDDireccion = ', @Dir, N', @LlaveIdempotencia = ''LLAVE-QA-AJENA''');
EXEC #Probar N'E10 No se puede usar la dirección de otro cliente', @S, 50182;
SET @S = CONCAT(N'EXEC SP_Pedidos_CrearPedido @IDUsuario = ', @Cli, N', @IDCarrito = ', @CartCli, N', @IDDireccion = ', @Dir, N', @LlaveIdempotencia = ''corta''');
EXEC #Probar N'E11 Llave de idempotencia demasiado corta', @S, 50126;
SET @S = CONCAT(N'EXEC SP_Pedidos_CrearPedido @IDUsuario = ', @Cli, N', @IDCarrito = ', @CartCli, N', @IDDireccion = 99999999, @LlaveIdempotencia = ''LLAVE-QA-DIRINEX''');
EXEC #Probar N'E12 Dirección inexistente', @S, 50181;
SET @S = CONCAT(N'EXEC SP_Pedidos_CrearPedido @IDUsuario = ', @Otro, N', @IDCarrito = ', @CartCli, N', @IDDireccion = ', @DirOtro, N', @LlaveIdempotencia = ''LLAVE-QA-CARRITOAJENO''');
EXEC #Probar N'E13 No se puede pagar el carrito de otro usuario', @S, 50142;
SET @S = CONCAT(N'EXEC SP_Pedidos_CrearPedido @IDUsuario = ', @Cli, N', @IDCarrito = ', @CartCli, N', @IDDireccion = ', @Dir, N', @LlaveIdempotencia = ''LLAVE-QA-SINRESERVA''');
EXEC #Probar N'E14 No se puede pagar sin haber reservado la existencia', @S, 50174;

-- Cambio de precio entre la reserva y el pago
SET @S = CONCAT(N'EXEC SP_Inventario_ReservarExistencia @IDCarrito = ', @CartCli, N', @IDUsuario = ', @Cli);
EXEC #Probar N'E15 El cliente inicia el pago y se reserva su existencia', @S, 0;
SET @N = (SELECT COUNT(*) FROM ReservasExistencia WHERE IDCarrito = @CartCli AND Estado = 'ACTIVA');
SET @Ok = CASE WHEN @N = 2 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'reservas activas=', @N, N' esperado=2');
EXEC #Verificar N'E16 Se reserva cada variante del carrito', @Ok, @Det;

SET @Dec = (SELECT Precio FROM VariantesProducto WHERE IDVariante = @VPoloMAz);
SET @S = CONCAT(N'EXEC SP_Variantes_CambiarPrecio @IDVariante = ', @VPoloMAz, N', @PrecioNuevo = 150.00, @IDUsuarioAccion = ', @Admin);
EXEC #Probar N'E17 El administrador sube el precio durante el pago', @S, 0;
SET @S = CONCAT(N'EXEC SP_Pedidos_CrearPedido @IDUsuario = ', @Cli, N', @IDCarrito = ', @CartCli, N', @IDDireccion = ', @Dir, N', @LlaveIdempotencia = ''LLAVE-QA-PRECIO''');
EXEC #Probar N'E18 Si el precio cambió desde la reserva se pide reiniciar el pago', @S, 50175;
SET @S = CONCAT(N'EXEC SP_Variantes_CambiarPrecio @IDVariante = ', @VPoloMAz, N', @PrecioNuevo = ', @Dec, N', @IDUsuarioAccion = ', @Admin);
EXEC #Probar N'E19 Se restituye el precio original', @S, 0;

-- Pedido real (idempotente)
SET @StockAntes = (SELECT ExistenciaFisica FROM VariantesProducto WHERE IDVariante = @VPoloMAz);
SET @UsosAntes = (SELECT UsosActuales FROM Cupones WHERE IDCupon = @IDRopa15);

SET @S = CONCAT(N'EXEC SP_Pedidos_CrearPedido @IDUsuario = ', @Cli, N', @IDCarrito = ', @CartCli, N', @IDDireccion = ', @Dir, N', @LlaveIdempotencia = ''LLAVE-QA-0001''');
EXEC #Probar N'E20 Crear pedido con cupón y pago simulado', @S, 0;
SET @P1 = (SELECT IDPedido FROM Pedidos WHERE IDUsuario = @Cli AND LlaveIdempotencia = 'LLAVE-QA-0001');
SET @Ok = CASE WHEN @P1 IS NOT NULL THEN 1 ELSE 0 END;
EXEC #Verificar N'E21 El pedido quedó guardado', @Ok, N'no existe el pedido';
IF @P1 IS NULL
BEGIN
    PRINT N'SE DETIENE: no se creó el pedido P1 (LLAVE-QA-0001); las pruebas siguientes dependen de él. Corrija la falla anterior y vuelva a ejecutar sobre una base nueva.';
    EXEC #Resumen;
    RETURN;
END;

EXEC #Probar N'E22 Repetir la misma solicitud (doble clic / reintento) no falla', @S, 0;
SET @N = (SELECT COUNT(*) FROM Pedidos WHERE IDUsuario = @Cli AND LlaveIdempotencia = 'LLAVE-QA-0001');
SET @N2 = (SELECT COUNT(*) FROM Pagos WHERE IDPedido = @P1);
SET @Ok = CASE WHEN @N = 1 AND @N2 = 1 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'pedidos=', @N, N' pagos=', @N2, N' (esperado 1 y 1)');
EXEC #Verificar N'E23 La repetición no genera dos pedidos ni dos cobros', @Ok, @Det;

SET @StockDespues = (SELECT ExistenciaFisica FROM VariantesProducto WHERE IDVariante = @VPoloMAz);
SET @Ok = CASE WHEN @StockAntes - @StockDespues = 2 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'antes=', @StockAntes, N' después=', @StockDespues, N' (esperado -2, una sola vez)');
EXEC #Verificar N'E24 La existencia bajó una sola vez', @Ok, @Det;

SELECT @Dec = Total, @Dec2 = Descuento FROM Pedidos WHERE IDPedido = @P1;
SET @Ok = CASE WHEN @Dec2 = 44.70 AND @Dec = 403.30 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'total=', @Dec, N' descuento=', @Dec2, N' (esperado 403.30 y 44.70)');
EXEC #Verificar N'E25 Totales del pedido (subtotal 448.00 - descuento 44.70)', @Ok, @Det;

SET @Dec = (SELECT SUM(TotalLinea) FROM PedidoDetalle WHERE IDPedido = @P1);
SET @Dec2 = (SELECT Total FROM Pedidos WHERE IDPedido = @P1);
SET @Ok = CASE WHEN @Dec = @Dec2 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'suma de líneas=', @Dec, N' total=', @Dec2);
EXEC #Verificar N'E26 La suma de las líneas coincide con el total (sin errores de redondeo)', @Ok, @Det;

SET @Ok = CASE WHEN (SELECT e.NombreEstado FROM Pedidos p JOIN EstadosPedido e ON e.IDEstadoPedido = p.IDEstadoPedido WHERE p.IDPedido = @P1) = N'Pagado' THEN 1 ELSE 0 END;
EXEC #Verificar N'E27 El pedido quedó en estado Pagado', @Ok, N'estado distinto de Pagado';

SET @N = (SELECT COUNT(*) FROM HistorialEstadosPedido WHERE IDPedido = @P1);
SET @Ok = CASE WHEN @N = 2 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'registros de historial=', @N, N' esperado=2');
EXEC #Verificar N'E28 El historial guarda creación y pago', @Ok, @Det;

SET @Ok = CASE WHEN (SELECT UsosActuales FROM Cupones WHERE IDCupon = @IDRopa15) = @UsosAntes + 1
                AND (SELECT COUNT(*) FROM UsosCupon WHERE IDPedido = @P1) = 1 THEN 1 ELSE 0 END;
EXEC #Verificar N'E29 El uso del cupón se registró una sola vez', @Ok, N'uso de cupón incorrecto';

SET @Ok = CASE WHEN (SELECT Estado FROM Carritos WHERE IDCarrito = @CartCli) = 'CONVERTIDO' THEN 1 ELSE 0 END;
EXEC #Verificar N'E30 El carrito quedó convertido', @Ok, N'el carrito sigue activo';

SET @N = (SELECT COUNT(*) FROM MovimientosInventario WHERE IDPedido = @P1 AND TipoMovimiento = 'SALIDA');
SET @Ok = CASE WHEN @N = 2 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'salidas en kardex=', @N, N' esperado=2');
EXEC #Verificar N'E31 Las salidas quedaron en el kardex', @Ok, @Det;

SET @Ok = CASE WHEN (SELECT COUNT(*) FROM ReservasExistencia WHERE IDCarrito = @CartCli AND Estado = 'CONFIRMADA' AND IDPedido = @P1) = 2 THEN 1 ELSE 0 END;
EXEC #Verificar N'E32 Las reservas se confirmaron con el pedido', @Ok, N'reservas sin confirmar';

SET @S = CONCAT(N'EXEC SP_Pedidos_CrearPedido @IDUsuario = ', @Cli, N', @IDCarrito = ', @CartCli, N', @IDDireccion = ', @Dir, N', @LlaveIdempotencia = ''LLAVE-QA-OTRA''');
EXEC #Probar N'E33 Un carrito ya convertido no puede pagarse otra vez con otra llave', @S, 50145;

DELETE FROM #K; INSERT INTO #K EXEC SP_Inventario_VerificarKardex;
SET @N = (SELECT COUNT(*) FROM #K);
SET @Ok = CASE WHEN @N = 0 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'variantes con diferencia: ', @N);
EXEC #Verificar N'E34 Existencia = suma del kardex después del pedido', @Ok, @Det;

-- Límite de uso del cupón por cliente
DELETE FROM #C; INSERT INTO #C EXEC SP_Carrito_ObtenerOCrear @IDUsuario = @Cli;
SET @CartCli2 = (SELECT TOP (1) IDCarrito FROM #C);
SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartCli2, N', @IDVariante = ', @VPoloMAz, N', @Cantidad = 1, @IDUsuario = ', @Cli);
EXEC #Probar N'E40 Nuevo carrito del cliente', @S, 0;
SET @S = CONCAT(N'EXEC SP_Carrito_AplicarCupon @IDCarrito = ', @CartCli2, N', @IDUsuario = ', @Cli, N', @Codigo = ''ROPA15''');
EXEC #Probar N'E41 Cupón ya usado el máximo de veces por ese cliente', @S, 50157;

-- Pedido del segundo cliente (con la última unidad)
SET @S = CONCAT(N'EXEC SP_Pedidos_CrearPedido @IDUsuario = ', @Otro, N', @IDCarrito = ', @CartOtro, N', @IDDireccion = ', @DirOtro, N', @LlaveIdempotencia = ''LLAVE-QA-0003''');
EXEC #Probar N'E42 El segundo cliente completa su compra de la última unidad', @S, 0;
SET @P3 = (SELECT IDPedido FROM Pedidos WHERE IDUsuario = @Otro AND LlaveIdempotencia = 'LLAVE-QA-0003');
IF @P3 IS NULL
BEGIN
    PRINT N'SE DETIENE: no se creó el pedido P3 (segundo cliente); las pruebas siguientes dependen de él. Corrija la falla anterior y vuelva a ejecutar sobre una base nueva.';
    EXEC #Resumen;
    RETURN;
END;
SET @N = (SELECT ExistenciaFisica FROM VariantesProducto WHERE IDVariante = @VPoloLBl);
SET @Ok = CASE WHEN @N = 0 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'existencia de la última unidad=', @N, N' esperado=0');
EXEC #Verificar N'E43 La existencia quedó en 0, nunca negativa', @Ok, @Det;

------------------------------------------------------------------
-- F. GESTIÓN DE PEDIDOS Y CANCELACIÓN
------------------------------------------------------------------
SET @S = CONCAT(N'EXEC SP_Pedidos_AvanzarEstado @IDPedido = ', @P1, N', @NuevoEstado = N''En preparación'', @IDUsuarioAccion = ', @Cli);
EXEC #Probar N'F01 Un cliente no puede avanzar estados', @S, 50103;
SET @S = CONCAT(N'EXEC SP_Pedidos_AvanzarEstado @IDPedido = ', @P1, N', @NuevoEstado = N''Despachado'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'F02 No se puede saltar de Pagado a Despachado', @S, 50192;
SET @S = CONCAT(N'EXEC SP_Pedidos_AvanzarEstado @IDPedido = ', @P1, N', @NuevoEstado = N''Inventado'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'F03 Estado inexistente', @S, 50193;
SET @S = CONCAT(N'EXEC SP_Pedidos_AvanzarEstado @IDPedido = ', @P1, N', @NuevoEstado = N''Cancelado'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'F04 Cancelar no se hace con el avance de estado', @S, 50191;
SET @S = CONCAT(N'EXEC SP_Pedidos_AvanzarEstado @IDPedido = 99999999, @NuevoEstado = N''En preparación'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'F05 Avanzar un pedido inexistente', @S, 50184;
SET @S = CONCAT(N'EXEC SP_Pedidos_AvanzarEstado @IDPedido = ', @P1, N', @NuevoEstado = N''En preparación'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'F06 El operador prepara el pedido', @S, 0;

SET @S = CONCAT(N'EXEC SP_Pedidos_ObtenerDetalle @IDPedido = ', @P1, N', @IDUsuarioSolicitante = ', @Otro);
EXEC #Probar N'F07 Un cliente no puede ver el pedido de otro', @S, 50183;
SET @S = CONCAT(N'EXEC SP_Pedidos_ObtenerDetalle @IDPedido = 99999999, @IDUsuarioSolicitante = ', @Cli);
EXEC #Probar N'F08 Pedido inexistente', @S, 50184;
SET @S = CONCAT(N'EXEC SP_Pedidos_ObtenerDetalle @IDPedido = ', @P1, N', @IDUsuarioSolicitante = ', @Cli);
EXEC #Probar N'F09 El cliente ve su propio pedido', @S, 0;
SET @S = CONCAT(N'EXEC SP_Pedidos_ObtenerDetalle @IDPedido = ', @P1, N', @IDUsuarioSolicitante = ', @Op);
EXEC #Probar N'F10 El operador ve cualquier pedido', @S, 0;
SET @S = CONCAT(N'EXEC SP_Pedidos_Cancelar @IDPedido = ', @P1, N', @IDUsuarioSolicitante = ', @Otro, N', @Motivo = N''no es mío''');
EXEC #Probar N'F11 Un cliente no puede cancelar el pedido de otro', @S, 50183;
SET @S = CONCAT(N'EXEC SP_Pedidos_Cancelar @IDPedido = ', @P1, N', @IDUsuarioSolicitante = ', @Cli, N', @Motivo = N''''');
EXEC #Probar N'F12 Cancelar exige motivo', @S, 50133;

-- Devolución antes de entregar
SELECT TOP (1) @L1 = IDPedidoDetalle FROM PedidoDetalle WHERE IDPedido = @P1 ORDER BY IDPedidoDetalle;
SET @S = CONCAT(N'DECLARE @L TT_Devoluciones_Lineas; INSERT INTO @L VALUES (', @L1, N', 1); ',
                N'EXEC SP_Pedidos_RegistrarDevolucion @IDPedido = ', @P1, N', @Motivo = N''prueba'', @Lineas = @L, @IDUsuarioAccion = ', @Op);
EXEC #Probar N'F13 No hay devolución de un pedido que aún no se entrega', @S, 50201;

SET @StockAntes = (SELECT ExistenciaFisica FROM VariantesProducto WHERE IDVariante = @VPoloMAz);
SET @S = CONCAT(N'EXEC SP_Pedidos_Cancelar @IDPedido = ', @P1, N', @IDUsuarioSolicitante = ', @Cli, N', @Motivo = N''Ya no lo necesito''');
EXEC #Probar N'F14 El cliente cancela su pedido antes del despacho', @S, 0;
SET @StockDespues = (SELECT ExistenciaFisica FROM VariantesProducto WHERE IDVariante = @VPoloMAz);
SET @Ok = CASE WHEN @StockDespues - @StockAntes = 2 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'antes=', @StockAntes, N' después=', @StockDespues, N' (esperado +2)');
EXEC #Verificar N'F15 Cancelar reintegra la existencia', @Ok, @Det;
SET @N = (SELECT COUNT(*) FROM MovimientosInventario WHERE IDPedido = @P1 AND TipoMovimiento = 'DEVOLUCION');
SET @Ok = CASE WHEN @N = 2 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'movimientos de devolución=', @N, N' esperado=2');
EXEC #Verificar N'F16 El reintegro quedó en el kardex', @Ok, @Det;
SET @Ok = CASE WHEN (SELECT Estado FROM Pagos WHERE IDPedido = @P1) = 'REEMBOLSADO' THEN 1 ELSE 0 END;
EXEC #Verificar N'F17 El pago del pedido cancelado quedó reembolsado', @Ok, N'pago no reembolsado';
EXEC #Probar N'F18 No se puede cancelar dos veces', @S, 50192;

------------------------------------------------------------------
-- G. DEVOLUCIONES (pedido 2: 3 gorras rojas)
------------------------------------------------------------------
-- Se reutiliza el carrito activo del cliente (creado en E40) quitándole el polo para que el pedido tenga una sola línea
DELETE FROM #C; INSERT INTO #C EXEC SP_Carrito_ObtenerOCrear @IDUsuario = @Cli;
SET @CartCli3 = (SELECT TOP (1) IDCarrito FROM #C);
SET @S = CONCAT(N'EXEC SP_Carrito_EliminarProducto @IDCarrito = ', @CartCli3, N', @IDVariante = ', @VPoloMAz, N', @IDUsuario = ', @Cli);
EXEC #Probar N'G00 Vaciar el polo del carrito activo', @S, 0;
SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartCli3, N', @IDVariante = ', @VGorraRj, N', @Cantidad = 3, @IDUsuario = ', @Cli);
EXEC #Probar N'G01 Carrito con 3 gorras rojas', @S, 0;
SET @S = CONCAT(N'EXEC SP_Inventario_ReservarExistencia @IDCarrito = ', @CartCli3, N', @IDUsuario = ', @Cli);
EXEC #Probar N'G02 Reservar', @S, 0;
SET @S = CONCAT(N'EXEC SP_Pedidos_CrearPedido @IDUsuario = ', @Cli, N', @IDCarrito = ', @CartCli3, N', @IDDireccion = ', @Dir, N', @LlaveIdempotencia = ''LLAVE-QA-0002''');
EXEC #Probar N'G03 Crear el pedido sin cupón', @S, 0;
SET @P2 = (SELECT IDPedido FROM Pedidos WHERE IDUsuario = @Cli AND LlaveIdempotencia = 'LLAVE-QA-0002');
IF @P2 IS NULL
BEGIN
    PRINT N'SE DETIENE: no se creó el pedido P2 (devoluciones); las pruebas siguientes dependen de él. Corrija la falla anterior y vuelva a ejecutar sobre una base nueva.';
    EXEC #Resumen;
    RETURN;
END;

SET @S = CONCAT(N'EXEC SP_Pedidos_AvanzarEstado @IDPedido = ', @P2, N', @NuevoEstado = N''En preparación'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'G04 Preparar', @S, 0;
SET @S = CONCAT(N'EXEC SP_Pedidos_AvanzarEstado @IDPedido = ', @P2, N', @NuevoEstado = N''Despachado'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'G05 Despachar', @S, 0;
SET @S = CONCAT(N'EXEC SP_Pedidos_Cancelar @IDPedido = ', @P2, N', @IDUsuarioSolicitante = ', @Cli, N', @Motivo = N''tarde''');
EXEC #Probar N'G06 No se puede cancelar un pedido despachado', @S, 50192;
SET @S = CONCAT(N'EXEC SP_Pedidos_AvanzarEstado @IDPedido = ', @P2, N', @NuevoEstado = N''Entregado'', @IDUsuarioAccion = ', @Op);
EXEC #Probar N'G07 Entregar', @S, 0;

SELECT TOP (1) @L2 = IDPedidoDetalle FROM PedidoDetalle WHERE IDPedido = @P2 ORDER BY IDPedidoDetalle;
SELECT TOP (1) @L3 = IDPedidoDetalle FROM PedidoDetalle WHERE IDPedido = @P3 ORDER BY IDPedidoDetalle;

SET @S = CONCAT(N'DECLARE @L TT_Devoluciones_Lineas; EXEC SP_Pedidos_RegistrarDevolucion @IDPedido = ', @P2, N', @Motivo = N''prueba'', @Lineas = @L, @IDUsuarioAccion = ', @Op);
EXEC #Probar N'G08 Devolución sin líneas', @S, 50204;
SET @S = CONCAT(N'DECLARE @L TT_Devoluciones_Lineas; INSERT INTO @L VALUES (', @L2, N', 1); EXEC SP_Pedidos_RegistrarDevolucion @IDPedido = ', @P2, N', @Motivo = N'''', @Lineas = @L, @IDUsuarioAccion = ', @Op);
EXEC #Probar N'G09 Devolución sin motivo', @S, 50133;
SET @S = CONCAT(N'DECLARE @L TT_Devoluciones_Lineas; INSERT INTO @L VALUES (', @L3, N', 1); EXEC SP_Pedidos_RegistrarDevolucion @IDPedido = ', @P2, N', @Motivo = N''prueba'', @Lineas = @L, @IDUsuarioAccion = ', @Op);
EXEC #Probar N'G10 Línea que pertenece a otro pedido', @S, 50202;
SET @S = CONCAT(N'DECLARE @L TT_Devoluciones_Lineas; INSERT INTO @L VALUES (', @L2, N', 4); EXEC SP_Pedidos_RegistrarDevolucion @IDPedido = ', @P2, N', @Motivo = N''prueba'', @Lineas = @L, @IDUsuarioAccion = ', @Op);
EXEC #Probar N'G11 No se puede devolver más de lo vendido (4 de 3)', @S, 50203;
SET @S = CONCAT(N'DECLARE @L TT_Devoluciones_Lineas; INSERT INTO @L VALUES (', @L2, N', 1); EXEC SP_Pedidos_RegistrarDevolucion @IDPedido = ', @P2, N', @Motivo = N''prueba'', @Lineas = @L, @IDUsuarioAccion = ', @Cli);
EXEC #Probar N'G12 Un cliente no registra devoluciones', @S, 50103;

SET @S = CONCAT(N'DECLARE @L TT_Devoluciones_Lineas; INSERT INTO @L VALUES (', @L2, N', 1); EXEC SP_Pedidos_RegistrarDevolucion @IDPedido = ', @P2, N', @Motivo = N''Talla incorrecta'', @Lineas = @L, @IDUsuarioAccion = ', @Op);
EXEC #Probar N'G13 Devolución parcial (1 de 3)', @S, 0;
SET @Ok = CASE WHEN (SELECT e.NombreEstado FROM Pedidos p JOIN EstadosPedido e ON e.IDEstadoPedido = p.IDEstadoPedido WHERE p.IDPedido = @P2) = N'Devuelto parcial' THEN 1 ELSE 0 END;
EXEC #Verificar N'G14 El pedido pasa a Devuelto parcial', @Ok, N'estado incorrecto';
SET @Dec = (SELECT SUM(MontoReembolso) FROM Devoluciones WHERE IDPedido = @P2);
SET @Ok = CASE WHEN @Dec = 75.00 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'reembolso=', @Dec, N' esperado=75.00');
EXEC #Verificar N'G15 Reembolso de la unidad devuelta', @Ok, @Det;

SET @S = CONCAT(N'DECLARE @L TT_Devoluciones_Lineas; INSERT INTO @L VALUES (', @L2, N', 3); EXEC SP_Pedidos_RegistrarDevolucion @IDPedido = ', @P2, N', @Motivo = N''prueba'', @Lineas = @L, @IDUsuarioAccion = ', @Op);
EXEC #Probar N'G16 El tope considera lo ya devuelto (1 + 3 > 3)', @S, 50203;

SET @S = CONCAT(N'DECLARE @L TT_Devoluciones_Lineas; INSERT INTO @L VALUES (', @L2, N', 2); EXEC SP_Pedidos_RegistrarDevolucion @IDPedido = ', @P2, N', @Motivo = N''Resto del pedido'', @Lineas = @L, @IDUsuarioAccion = ', @Op);
EXEC #Probar N'G17 Segunda devolución que completa el pedido', @S, 0;
SET @Ok = CASE WHEN (SELECT e.NombreEstado FROM Pedidos p JOIN EstadosPedido e ON e.IDEstadoPedido = p.IDEstadoPedido WHERE p.IDPedido = @P2) = N'Devuelto' THEN 1 ELSE 0 END;
EXEC #Verificar N'G18 El pedido pasa a Devuelto', @Ok, N'estado incorrecto';
SET @Dec = (SELECT SUM(MontoReembolso) FROM Devoluciones WHERE IDPedido = @P2);
SET @Dec2 = (SELECT Total FROM Pedidos WHERE IDPedido = @P2);
SET @Ok = CASE WHEN @Dec = @Dec2 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'reembolsado=', @Dec, N' total=', @Dec2);
EXEC #Verificar N'G19 Lo reembolsado suma exactamente el total del pedido', @Ok, @Det;

SET @S = CONCAT(N'DECLARE @L TT_Devoluciones_Lineas; INSERT INTO @L VALUES (', @L2, N', 1); EXEC SP_Pedidos_RegistrarDevolucion @IDPedido = ', @P2, N', @Motivo = N''prueba'', @Lineas = @L, @IDUsuarioAccion = ', @Op);
EXEC #Probar N'G20 Un pedido ya devuelto no admite más devoluciones', @S, 50201;

DELETE FROM #K; INSERT INTO #K EXEC SP_Inventario_VerificarKardex;
SET @N = (SELECT COUNT(*) FROM #K);
SET @Ok = CASE WHEN @N = 0 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'variantes con diferencia: ', @N);
EXEC #Verificar N'G21 Existencia = suma del kardex después de cancelaciones y devoluciones', @Ok, @Det;

-- Pedido 4: queda "Pagado" para los reportes
DELETE FROM #C; INSERT INTO #C EXEC SP_Carrito_ObtenerOCrear @IDUsuario = @Cli;
SET @CartCli4 = (SELECT TOP (1) IDCarrito FROM #C);
SET @S = CONCAT(N'EXEC SP_Carrito_AgregarProducto @IDCarrito = ', @CartCli4, N', @IDVariante = ', @VJean30, N', @Cantidad = 1, @IDUsuario = ', @Cli);
EXEC #Probar N'G30 Carrito con un jean', @S, 0;
SET @S = CONCAT(N'EXEC SP_Inventario_ReservarExistencia @IDCarrito = ', @CartCli4, N', @IDUsuario = ', @Cli);
EXEC #Probar N'G31 Reservar', @S, 0;
SET @S = CONCAT(N'EXEC SP_Pedidos_CrearPedido @IDUsuario = ', @Cli, N', @IDCarrito = ', @CartCli4, N', @IDDireccion = ', @Dir, N', @LlaveIdempotencia = ''LLAVE-QA-0004''');
EXEC #Probar N'G32 Pedido que permanece pagado', @S, 0;

------------------------------------------------------------------
-- H. REGLAS DE LA BASE DE DATOS (se saltan los SP a propósito)
------------------------------------------------------------------
SET @S = CONCAT(N'UPDATE Pedidos SET IDEstadoPedido = (SELECT IDEstadoPedido FROM EstadosPedido WHERE NombreEstado = N''Pendiente de pago'') WHERE IDPedido = ', @P3);
EXEC #Probar N'H01 El trigger rechaza una transición de estado no permitida', @S, 50001;
SET @S = CONCAT(N'UPDATE VariantesProducto SET ExistenciaFisica = -1 WHERE IDVariante = ', @VGorraNg);
EXEC #Probar N'H02 CHECK: la existencia no puede ser negativa', @S, 547;
SET @S = CONCAT(N'UPDATE VariantesProducto SET Precio = -1 WHERE IDVariante = ', @VGorraNg);
EXEC #Probar N'H03 CHECK: el precio no puede ser negativo', @S, 547;
SET @S = CONCAT(N'UPDATE PedidoDetalle SET CantidadDevuelta = Cantidad + 1 WHERE IDPedidoDetalle = ', @L2);
EXEC #Probar N'H04 CHECK: no se devuelve más de lo vendido', @S, 547;
SET @S = N'UPDATE Cupones SET UsosActuales = LimiteUsosTotal + 1 WHERE Codigo = ''BIENVENIDO10''';
EXEC #Probar N'H05 CHECK: los usos del cupón nunca superan el límite', @S, 547;
EXEC #Probar N'H06 La bitácora no se puede modificar', N'UPDATE Bitacora SET Accion = ''CREAR''', 50002;
EXEC #Probar N'H07 La bitácora no se puede eliminar', N'DELETE FROM Bitacora', 50002;
SET @S = CONCAT(N'INSERT INTO MovimientosInventario (IDVariante, IDUsuario, TipoMovimiento, Cantidad, ExistenciaResultante, Motivo) VALUES (', @VGorraNg, N', ', @Op, N', ''SALIDA'', 5, 10, N''signo incorrecto'')');
EXEC #Probar N'H08 CHECK: una salida de kardex debe ser negativa', @S, 547;
SET @S = CONCAT(N'INSERT INTO Pedidos (IDUsuario, IDDireccion, IDEstadoPedido, Subtotal, Descuento, Total, MontoIVA, LlaveIdempotencia) VALUES (', @Cli, N', ', @Dir, N', 1, 100, 150, -50, 0, ''LLAVE-QA-NEGATIVA'')');
EXEC #Probar N'H09 CHECK: el descuento nunca deja el total por debajo de cero', @S, 547;
SET @S = CONCAT(N'INSERT INTO UsosCupon (IDCupon, IDUsuario, IDPedido) VALUES (', @IDRopa15, N', ', @Cli, N', ', @P1, N')');
EXEC #Probar N'H10 UNIQUE: un pedido no puede usar dos veces un cupón', @S, 2627;
EXEC #Probar N'H11 El kardex no se puede modificar', N'UPDATE MovimientosInventario SET Motivo = N''x''', 50003;
EXEC #Probar N'H12 El kardex no se puede eliminar', N'DELETE FROM MovimientosInventario', 50003;
EXEC #Probar N'H13 El historial de estados no se puede modificar', N'UPDATE HistorialEstadosPedido SET Comentario = N''x''', 50003;
EXEC #Probar N'H14 Un pedido no se puede eliminar', N'DELETE FROM Pedidos', 50003;
EXEC #Probar N'H15 Un pago no se puede eliminar', N'DELETE FROM Pagos', 50003;
SET @S = CONCAT(N'INSERT INTO VariantesProducto (IDProducto, SKU, Talla, Color, Precio) SELECT IDProducto, ''QA-DUP'', Talla, Color, 10 FROM VariantesProducto WHERE IDVariante = ', @VPoloMAz);
EXEC #Probar N'H16 UNIQUE: no se repite la misma combinación de atributos en un producto', @S, 2601;
EXEC #Probar N'H17 CHECK: cantidad máxima por línea de carrito', N'UPDATE TOP (1) CarritoDetalle SET Cantidad = 1001', 547;
EXEC #Probar N'H18 CHECK: precio máximo', N'UPDATE TOP (1) VariantesProducto SET Precio = 99999999', 547;

------------------------------------------------------------------
-- I. LISTADOS Y REPORTES
------------------------------------------------------------------
SET @S = CONCAT(N'EXEC SP_Pedidos_Listar @IDUsuarioSolicitante = ', @Cli);
EXEC #Probar N'I01 Un cliente no puede listar todos los pedidos', @S, 50103;
SET @S = CONCAT(N'EXEC SP_Pedidos_Listar @IDUsuarioSolicitante = ', @Op, N', @Pagina = -3, @TamanoPagina = 0, @Ordenar = ''TOTAL_DESC''');
EXEC #Probar N'I02 Listado de pedidos con paginación extrema', @S, 0;
SET @S = CONCAT(N'EXEC SP_Pedidos_Listar @IDUsuarioSolicitante = ', @Op, N', @BuscarCliente = N''%'', @Desde = ''2000-01-01'', @Hasta = ''2099-12-31''');
EXEC #Probar N'I03 Listado con filtros de cliente y fechas', @S, 0;
SET @S = CONCAT(N'EXEC SP_Pedidos_ListarPorCliente @IDUsuario = ', @Cli, N', @Pagina = 0, @TamanoPagina = 100000');
EXEC #Probar N'I04 Pedidos del cliente', @S, 0;

SET @S = CONCAT(N'EXEC SP_Reportes_VentasPorPeriodo @IDUsuarioAccion = ', @Cli, N', @Desde = ''2000-01-01'', @Hasta = ''2099-12-31''');
EXEC #Probar N'I10 Un cliente no puede ver reportes', @S, 50103;
SET @S = CONCAT(N'EXEC SP_Reportes_VentasPorPeriodo @IDUsuarioAccion = ', @Op, N', @Desde = ''2000-01-01'', @Hasta = ''2099-12-31''');
EXEC #Probar N'I11 Un operador tampoco (solo el administrador)', @S, 50103;
SET @S = CONCAT(N'EXEC SP_Reportes_VentasPorPeriodo @IDUsuarioAccion = ', @Admin, N', @Desde = ''2000-01-01'', @Hasta = ''2099-12-31'', @Agrupacion = ''AÑO''');
EXEC #Probar N'I12 Agrupación inválida', @S, 50211;
SET @S = CONCAT(N'EXEC SP_Reportes_VentasPorPeriodo @IDUsuarioAccion = ', @Admin, N', @Desde = ''2099-01-01'', @Hasta = ''2000-01-01''');
EXEC #Probar N'I13 Rango de fechas invertido', @S, 50211;
SET @S = CONCAT(N'EXEC SP_Reportes_VentasPorPeriodo @IDUsuarioAccion = ', @Admin, N', @Desde = ''2000-01-01'', @Hasta = ''2099-12-31'', @Agrupacion = ''DIA''');
EXEC #Probar N'I14 Ventas por día', @S, 0;
SET @S = CONCAT(N'EXEC SP_Reportes_VentasPorPeriodo @IDUsuarioAccion = ', @Admin, N', @Desde = ''2000-01-01'', @Hasta = ''2099-12-31'', @Agrupacion = ''SEMANA''');
EXEC #Probar N'I15 Ventas por semana', @S, 0;
SET @S = CONCAT(N'EXEC SP_Reportes_VentasPorPeriodo @IDUsuarioAccion = ', @Admin, N', @Desde = ''2000-01-01'', @Hasta = ''2099-12-31'', @Agrupacion = ''MES''');
EXEC #Probar N'I16 Ventas por mes', @S, 0;
SET @S = CONCAT(N'EXEC SP_Reportes_VentasPorCategoria @IDUsuarioAccion = ', @Admin, N', @Desde = ''2000-01-01'', @Hasta = ''2099-12-31''');
EXEC #Probar N'I17 Ventas por categoría', @S, 0;
SET @S = CONCAT(N'EXEC SP_Reportes_TopProductos @IDUsuarioAccion = ', @Admin, N', @Desde = ''2000-01-01'', @Hasta = ''2099-12-31'', @Top = 0');
EXEC #Probar N'I18 Top de productos con Top = 0 se normaliza a 10', @S, 0;
SET @S = CONCAT(N'EXEC SP_Reportes_TopProductos @IDUsuarioAccion = ', @Admin, N', @Desde = ''2000-01-01'', @Hasta = ''2099-12-31'', @Top = 100000');
EXEC #Probar N'I19 Top de productos con Top enorme', @S, 0;
SET @S = CONCAT(N'EXEC SP_Reportes_Resumen @IDUsuarioAccion = ', @Admin, N', @Desde = ''2000-01-01'', @Hasta = ''2099-12-31''');
EXEC #Probar N'I20 Resumen del dashboard', @S, 0;
SET @S = CONCAT(N'EXEC SP_Reportes_CarritosAbandonados @IDUsuarioAccion = ', @Admin, N', @MinutosInactividad = 0, @Pagina = 0, @TamanoPagina = 100000');
EXEC #Probar N'I21 Carritos abandonados', @S, 0;

-- Los reportes solo cuentan pedidos completados: el pedido 1 (cancelado) y el 2 (devuelto) no suman
SET @Dec = (SELECT ISNULL(SUM(TotalNeto), 0) FROM VW_Reportes_PedidosCompletados);
SET @Dec2 = (SELECT ISNULL(SUM(Total), 0) FROM Pedidos WHERE IDPedido IN (@P3, (SELECT IDPedido FROM Pedidos WHERE LlaveIdempotencia = 'LLAVE-QA-0004')));
SET @Ok = CASE WHEN @Dec = @Dec2 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'reportes=', @Dec, N' pedidos completados=', @Dec2);
EXEC #Verificar N'I30 Los reportes excluyen cancelados y devueltos', @Ok, @Det;

------------------------------------------------------------------
-- J. BITÁCORA
------------------------------------------------------------------
SET @S = CONCAT(N'EXEC SP_Bitacora_Listar @IDUsuarioAccion = ', @Cli);
EXEC #Probar N'J01 Un cliente no consulta la bitácora', @S, 50103;
SET @S = CONCAT(N'EXEC SP_Bitacora_Listar @IDUsuarioAccion = ', @Admin, N', @Modulo = ''Pedidos'', @Pagina = 0, @TamanoPagina = 100000');
EXEC #Probar N'J02 El administrador consulta la bitácora filtrada por módulo', @S, 0;

SET @N = (SELECT COUNT(*) FROM Bitacora WHERE Modulo = 'Pedidos');
SET @Ok = CASE WHEN @N > 0 THEN 1 ELSE 0 END;
EXEC #Verificar N'J03 Los cambios de pedidos quedaron registrados', @Ok, N'sin registros de pedidos en la bitácora';
SET @N = (SELECT COUNT(*) FROM Bitacora WHERE Modulo = 'Precios' AND ValorAnterior IS NOT NULL AND ValorNuevo IS NOT NULL);
SET @Ok = CASE WHEN @N >= 2 THEN 1 ELSE 0 END;
EXEC #Verificar N'J04 Los cambios de precio guardan valor anterior y nuevo', @Ok, N'faltan registros de precios';
SET @N = (SELECT COUNT(*) FROM Bitacora WHERE Modulo = 'Inventario');
SET @Ok = CASE WHEN @N > 0 THEN 1 ELSE 0 END;
EXEC #Verificar N'J05 Los ajustes de inventario quedaron registrados', @Ok, N'sin registros de inventario';

------------------------------------------------------------------
-- K. DIRECCIONES Y ESTADOS DE PEDIDO (script 016)
------------------------------------------------------------------
IF OBJECT_ID('SP_Direcciones_Crear') IS NULL OR OBJECT_ID('SP_Pedidos_ListarEstados') IS NULL
BEGIN
    EXEC #Verificar N'K00 El script 016 está instalado (direcciones y estados)', 0, N'faltan SP_Direcciones_* o SP_Pedidos_ListarEstados: ejecute 016_Direcciones_Estados.sql';
END
ELSE
BEGIN
    DECLARE @DirNueva INT;

    IF OBJECT_ID('tempdb..#DirL') IS NOT NULL DROP TABLE #DirL;
    CREATE TABLE #DirL (IDDireccion INT, Direccion NVARCHAR(200), Zona NVARCHAR(50), Municipio NVARCHAR(100), Departamento NVARCHAR(100),
                        Referencia NVARCHAR(255), CodigoPostal VARCHAR(20), FechaCreacion DATETIME2(7));
    IF OBJECT_ID('tempdb..#EstL') IS NOT NULL DROP TABLE #EstL;
    CREATE TABLE #EstL (IDEstadoPedido INT, NombreEstado NVARCHAR(100));

    SET @S = CONCAT(N'EXEC SP_Direcciones_Crear @IDUsuario = ', @Cli,
                    N', @Direccion = N''QA 016 calle 1'', @Zona = N''4'', @Municipio = N''Asunción Mita'', @Departamento = N''Jutiapa''');
    EXEC #Probar N'K01 Un cliente crea una dirección de entrega', @S, 0;
    SET @DirNueva = (SELECT TOP (1) IDDireccion FROM Direcciones WHERE IDUsuario = @Cli AND Direccion = N'QA 016 calle 1' ORDER BY IDDireccion DESC);
    SET @Ok = CASE WHEN @DirNueva IS NOT NULL AND EXISTS (SELECT 1 FROM Direcciones WHERE IDDireccion = @DirNueva AND Activo = 1) THEN 1 ELSE 0 END;
    EXEC #Verificar N'K02 La dirección creada queda activa y a nombre del cliente', @Ok, N'no se encontró la dirección creada';

    SET @S = CONCAT(N'EXEC SP_Direcciones_Crear @IDUsuario = ', @Cli, N', @Direccion = N''QA sin municipio'', @Municipio = N''   '', @Departamento = N''Jutiapa''');
    EXEC #Probar N'K03 No se crea una dirección sin municipio', @S, 50126;

    EXEC #Probar N'K04 No se crea una dirección para un usuario inexistente',
         N'EXEC SP_Direcciones_Crear @IDUsuario = 0, @Direccion = N''QA fantasma'', @Municipio = N''X'', @Departamento = N''Y''', 50104;

    DELETE FROM #DirL;
    INSERT INTO #DirL EXEC SP_Direcciones_Listar @IDUsuario = @Cli;
    SET @N = (SELECT COUNT(*) FROM #DirL);
    SET @N2 = (SELECT COUNT(*) FROM #DirL l WHERE NOT EXISTS (SELECT 1 FROM Direcciones d WHERE d.IDDireccion = l.IDDireccion AND d.IDUsuario = @Cli));
    SET @Ok = CASE WHEN @N >= 2 AND @N2 = 0 AND EXISTS (SELECT 1 FROM #DirL WHERE IDDireccion = @DirNueva) THEN 1 ELSE 0 END;
    SET @Det = CONCAT(N'listadas=', @N, N' ajenas=', @N2);
    EXEC #Verificar N'K05 El listado trae las direcciones del cliente (la semilla y la nueva) y ninguna ajena', @Ok, @Det;

    DELETE FROM #DirL;
    INSERT INTO #DirL EXEC SP_Direcciones_Listar @IDUsuario = @Otro;
    SET @N = (SELECT COUNT(*) FROM #DirL WHERE IDDireccion = @DirNueva);
    SET @Ok = CASE WHEN @N = 0 THEN 1 ELSE 0 END;
    EXEC #Verificar N'K06 Otro cliente no ve la dirección de este cliente', @Ok, N'la dirección apareció en el listado de otro usuario';

    SET @S = CONCAT(N'EXEC SP_Direcciones_Desactivar @IDDireccion = ', @DirNueva, N', @IDUsuario = ', @Otro);
    EXEC #Probar N'K07 Otro cliente no puede desactivar una dirección ajena', @S, 50182;

    EXEC #Probar N'K08 Desactivar una dirección inexistente falla',
         N'EXEC SP_Direcciones_Desactivar @IDDireccion = 0, @IDUsuario = 1', 50181;

    SET @S = CONCAT(N'EXEC SP_Direcciones_Desactivar @IDDireccion = ', @DirNueva, N', @IDUsuario = ', @Cli);
    EXEC #Probar N'K09 El dueño desactiva su dirección', @S, 0;
    SET @Ok = CASE WHEN EXISTS (SELECT 1 FROM Direcciones WHERE IDDireccion = @DirNueva AND Activo = 0) THEN 1 ELSE 0 END;
    EXEC #Verificar N'K10 La dirección se desactiva pero NO se borra (los pedidos viejos la siguen usando)', @Ok, N'la fila no existe o sigue activa';

    DELETE FROM #DirL;
    INSERT INTO #DirL EXEC SP_Direcciones_Listar @IDUsuario = @Cli;
    SET @N = (SELECT COUNT(*) FROM #DirL WHERE IDDireccion = @DirNueva);
    SET @Ok = CASE WHEN @N = 0 THEN 1 ELSE 0 END;
    EXEC #Verificar N'K11 Una dirección desactivada ya no aparece en el listado', @Ok, N'la dirección desactivada sigue apareciendo';

    INSERT INTO #EstL EXEC SP_Pedidos_ListarEstados;
    SET @N = (SELECT COUNT(*) FROM #EstL);
    SET @N2 = (SELECT COUNT(*) FROM EstadosPedido);
    SET @Ok = CASE WHEN @N = @N2 AND @N > 0 AND EXISTS (SELECT 1 FROM #EstL WHERE NombreEstado = N'Pagado') THEN 1 ELSE 0 END;
    SET @Det = CONCAT(N'devueltos=', @N, N' existentes=', @N2);
    EXEC #Verificar N'K12 La lista de estados trae todos los estados del pedido', @Ok, @Det;
END;

------------------------------------------------------------------
-- RESUMEN
------------------------------------------------------------------
DELETE FROM #K; INSERT INTO #K EXEC SP_Inventario_VerificarKardex;
SET @N = (SELECT COUNT(*) FROM #K);
SET @Ok = CASE WHEN @N = 0 THEN 1 ELSE 0 END;
SET @Det = CONCAT(N'variantes con diferencia: ', @N);
EXEC #Verificar N'Z99 Al final: existencia = suma del kardex en todas las variantes', @Ok, @Det;

EXEC #Resumen;
GO

------------------------------------------------------------------
-- PRUEBA DE CONCURRENCIA REAL (manual, dos ventanas de SSMS)
-- Objetivo: dos clientes pagan a la vez la última unidad y solo uno lo logra.
--  1. Prepare dos carritos con la misma variante cuya existencia sea 1 (por ejemplo, ajuste
--     una variante a 1 con SP_Inventario_AjustarExistencia) y anote los IDCarrito / IDUsuario.
--  2. En la ventana A y en la ventana B escriba lo mismo, con su propio carrito y usuario,
--     y ejecute ambas dentro del mismo minuto (cambie la hora):
--
--       WAITFOR TIME '14:30:00';
--       EXEC SP_Inventario_ReservarExistencia @IDCarrito = <carrito>, @IDUsuario = <usuario>;
--
--  3. Resultado esperado: una ventana termina bien y la otra falla con el error 50172
--     ("No hay existencia suficiente..."). Después ejecute SP_Inventario_VerificarKardex:
--     no debe devolver filas, y ExistenciaFisica nunca debe ser menor que 0.
--  4. Haga la misma prueba con SP_Pedidos_CrearPedido y la MISMA @LlaveIdempotencia en las
--     dos ventanas: debe existir un solo pedido y un solo pago (la segunda devuelve Repetido = 1).
--  5. Repita con un cupón de LimiteUsosTotal = 1 usado por dos clientes distintos a la vez:
--     solo uno obtiene el descuento y el otro recibe el error 50155 (agotado).
------------------------------------------------------------------

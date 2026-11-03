-- 015_Permisos.sql  (OPCIONAL, ejecutar una vez, después del 014)
-- Usuario de la aplicación con acceso EXCLUSIVO a stored procedures:
-- no puede leer ni escribir tablas directamente. Cumple "todo acceso a datos por stored procedures".
--
-- ANTES DE EJECUTAR:
--   * Cambie la contraseña de @Clave por una propia. NO suba la contraseña real al repositorio;
--     el backend la toma de la variable de entorno DB_PASSWORD (.env, ignorado por git).
--   * El servidor debe permitir autenticación de SQL Server (modo mixto).
--   * Conéctese como administrador, con la base CarritoVenta seleccionada.
--
-- Luego configure el backend con DB_USER=ShopCartApp y la clave elegida.

DECLARE @Clave NVARCHAR(128) = N'CAMBIAR_ESTA_CLAVE_1a!';

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'ShopCartApp')
BEGIN
    DECLARE @CrearLogin NVARCHAR(400) =
        N'CREATE LOGIN ShopCartApp WITH PASSWORD = N''' + REPLACE(@Clave, '''', '''''') + N''', CHECK_POLICY = ON';
    EXEC (@CrearLogin);
END;
GO

IF DATABASE_PRINCIPAL_ID(N'ShopCartApp') IS NULL
    CREATE USER ShopCartApp FOR LOGIN ShopCartApp;
GO

IF DATABASE_PRINCIPAL_ID(N'rol_ShopCartApp') IS NULL
    CREATE ROLE rol_ShopCartApp;
GO

ALTER ROLE rol_ShopCartApp ADD MEMBER ShopCartApp;
GO

-- Puede ejecutar procedimientos (y usar los tipos TVP), nada más
GRANT EXECUTE ON SCHEMA::dbo TO rol_ShopCartApp;
GRANT EXECUTE ON TYPE::dbo.TT_Catalogo_Variantes TO rol_ShopCartApp;
GRANT EXECUTE ON TYPE::dbo.TT_Inventario_Entradas TO rol_ShopCartApp;
GRANT EXECUTE ON TYPE::dbo.TT_Devoluciones_Lineas TO rol_ShopCartApp;

-- Sin acceso directo a las tablas (los SP sí acceden por encadenamiento de propiedad)
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo TO rol_ShopCartApp;
GO

-- Comprobación sugerida, conectado como ShopCartApp:
--   EXEC SP_Categorias_Listar;        -- debe funcionar
--   SELECT * FROM Usuarios;            -- debe fallar con "permiso denegado"

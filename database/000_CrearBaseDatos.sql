-- 000_CrearBaseDatos.sql
-- Crea la base de datos de CarritoVenta desde cero.
--
-- ATENCIÓN: si la base ya existe se ELIMINA con todos sus datos. Cambie el nombre si su base
-- se llama distinto. Ejecutar conectado a la base "master" (o a cualquiera distinta de CarritoVenta).
--
-- Orden de ejecución de los scripts:
--   000_CrearBaseDatos.sql  ->  USE CarritoVenta  ->  001 ... 012  ->  013_Pruebas.sql (opcional)

USE master;
GO

IF DB_ID(N'CarritoVenta') IS NOT NULL
BEGIN
    ALTER DATABASE CarritoVenta SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE CarritoVenta;
END;
GO

CREATE DATABASE CarritoVenta;
GO

USE CarritoVenta;
GO

-- 008_SP_Acceso.sql
-- Auxiliares (bitácora y permisos) y procedimientos de autenticación y usuarios.
--
-- CÓDIGOS DE ERROR (THROW). El backend los traduce a HTTP:
--   50001 transición de estado no permitida (trigger)      -> 409
--   50002 bitácora inmutable (trigger)                     -> 403
--   50003 kardex, historial, pedidos y pagos no se modifican ni eliminan (trigger) -> 403
--   50199 procedimiento auxiliar fuera de transacción (error de programación) -> 500
--   SQL Server: 1205 deadlock -> reintentar la solicitud 1-2 veces;  1222 tiempo de bloqueo agotado -> 503
--   50101 correo duplicado -> 409      50103 sin permisos -> 403     50104 usuario no existe -> 404
--   50105 no puede desactivarse a sí mismo -> 409            50106 rol inexistente -> 400
--   50111 refresh token inválido -> 401   50112 reuso de token -> 401   50113 expirado -> 401
--   50114 usuario inactivo -> 403
--   50121 duplicado en catálogo -> 409   50122 categoría inválida -> 400   50123 producto no existe -> 404
--   50124 variante no existe -> 404      50125 producto sin variantes -> 400   50126 datos inválidos -> 400
--   50131 existencia negativa -> 409     50132 bajo lo reservado -> 409   50133 motivo obligatorio -> 400
--   50134 tipo de movimiento inválido -> 400   50135 cantidad inválida -> 400
--   50141 carrito no existe -> 404   50142 carrito ajeno -> 403   50143 producto no disponible -> 409
--   50144 excede existencia -> 409   50145 carrito inactivo -> 409   50146 línea inexistente -> 404
--   50147 cantidad inválida -> 400
--   50151..50159 cupones al aplicar (ver SP_Cupones_Validar)   50161 código duplicado -> 409
--   50162 datos de cupón inválidos -> 400   50163 cupón no existe -> 404
--   50171 carrito con productos no disponibles -> 409   50172 sin existencia suficiente -> 409
--   50173 carrito vacío -> 400   50174 reserva vencida -> 409   50175 el precio cambió -> 409
--   50181 dirección inválida -> 400   50182 dirección ajena -> 403   50183 pedido ajeno -> 403
--   50184 pedido no existe -> 404   50190 no se obtuvo el bloqueo -> 503
--   50191 estado no asignable por esta vía -> 400   50192 transición no permitida -> 409
--   50193 estado inexistente -> 400
--   50201 pedido no admite devolución -> 409   50202 línea ajena al pedido -> 400
--   50203 devolución excede lo vendido -> 409   50204 devolución sin líneas -> 400
--   50211 parámetro de reporte inválido -> 400

------------------------------------------------------------------
-- Auxiliares
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Bitacora_Registrar
    @IDUsuario     INT,
    @Modulo        VARCHAR(30),
    @Entidad       VARCHAR(50),
    @IDEntidad     VARCHAR(50),
    @Accion        VARCHAR(15),
    @ValorAnterior NVARCHAR(MAX) = NULL,
    @ValorNuevo    NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO Bitacora (IDUsuario, Modulo, Entidad, IDEntidad, Accion, ValorAnterior, ValorNuevo)
    VALUES (@IDUsuario, @Modulo, @Entidad, @IDEntidad, @Accion, @ValorAnterior, @ValorNuevo);
END;
GO

-- @Nivel: 'ADMIN' (solo Administrador) o 'PERSONAL' (Operador o Administrador)
CREATE OR ALTER PROCEDURE SP_Usuarios_ExigirRol
    @IDUsuario INT,
    @Nivel     VARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (
        SELECT 1
        FROM Usuarios u
        JOIN Roles r ON r.IDRol = u.IDRol
        WHERE u.IDUsuario = @IDUsuario
          AND u.Activo = 1
          AND (   (@Nivel = 'ADMIN'    AND r.NombreRol = N'Administrador')
               OR (@Nivel = 'PERSONAL' AND r.NombreRol IN (N'Administrador', N'Operador'))))
        THROW 50103, N'No tiene permisos para realizar esta acción.', 1;
END;
GO

------------------------------------------------------------------
-- Autenticación
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Auth_RegistrarCliente
    @Email          NVARCHAR(150),
    @NombreCompleto NVARCHAR(150),
    @PasswordHash   VARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @IDRol INT = (SELECT IDRol FROM Roles WHERE NombreRol = N'Cliente');
    DECLARE @IDUsuario INT;

    BEGIN TRY
        INSERT INTO Usuarios (Email, NombreCompleto, PasswordHash, IDRol)
        VALUES (LOWER(LTRIM(RTRIM(@Email))), LTRIM(RTRIM(@NombreCompleto)), @PasswordHash, @IDRol);
        SET @IDUsuario = SCOPE_IDENTITY();
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() IN (2601, 2627)
            THROW 50101, N'El correo ya está registrado.', 1;
        THROW;
    END CATCH;

    SELECT u.IDUsuario, u.Email, u.NombreCompleto, r.NombreRol
    FROM Usuarios u
    JOIN Roles r ON r.IDRol = u.IDRol
    WHERE u.IDUsuario = @IDUsuario;
END;
GO

-- El backend compara la contraseña con PasswordHash (bcrypt); nunca se compara en SQL.
CREATE OR ALTER PROCEDURE SP_Auth_ObtenerUsuarioPorEmail
    @Email NVARCHAR(150)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.IDUsuario, u.Email, u.NombreCompleto, u.PasswordHash, u.Activo, u.IDRol, r.NombreRol
    FROM Usuarios u
    JOIN Roles r ON r.IDRol = u.IDRol
    WHERE u.Email = LOWER(LTRIM(RTRIM(@Email)));
END;
GO

CREATE OR ALTER PROCEDURE SP_Auth_ObtenerUsuarioPorID
    @IDUsuario INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.IDUsuario, u.Email, u.NombreCompleto, u.Activo, u.IDRol, r.NombreRol
    FROM Usuarios u
    JOIN Roles r ON r.IDRol = u.IDRol
    WHERE u.IDUsuario = @IDUsuario;
END;
GO

CREATE OR ALTER PROCEDURE SP_Auth_GuardarRefreshToken
    @IDUsuario       INT,
    @TokenHash       CHAR(64),
    @FechaExpiracion DATETIME2(0),
    @DispositivoID   UNIQUEIDENTIFIER = NULL,
    @DireccionIP     VARCHAR(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Una sola sesión activa por dispositivo: se revoca la anterior
        IF @DispositivoID IS NOT NULL
            UPDATE RefreshTokens
            SET FechaRevocacion = SYSUTCDATETIME()
            WHERE IDUsuario = @IDUsuario AND DispositivoID = @DispositivoID AND FechaRevocacion IS NULL;

        INSERT INTO RefreshTokens (IDUsuario, TokenHash, FechaExpiracion, DispositivoID, DireccionIP)
        VALUES (@IDUsuario, @TokenHash, @FechaExpiracion, @DispositivoID, @DireccionIP);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

-- Rotación: el token actual se revoca y se emite uno nuevo. Si llega un token ya revocado
-- se asume robo: se revocan todas las sesiones del usuario.
CREATE OR ALTER PROCEDURE SP_Auth_RotarRefreshToken
    @TokenHashActual      CHAR(64),
    @TokenHashNuevo       CHAR(64),
    @FechaExpiracionNueva DATETIME2(0),
    @DireccionIP          VARCHAR(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @IDToken INT, @IDUsuario INT, @Revocado DATETIME2(0), @Expira DATETIME2(0),
            @Dispositivo UNIQUEIDENTIFIER, @UsuarioActivo BIT, @IDTokenNuevo INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @IDToken = t.IDToken, @IDUsuario = t.IDUsuario, @Revocado = t.FechaRevocacion,
               @Expira = t.FechaExpiracion, @Dispositivo = t.DispositivoID, @UsuarioActivo = u.Activo
        FROM RefreshTokens t WITH (UPDLOCK, HOLDLOCK)
        JOIN Usuarios u ON u.IDUsuario = t.IDUsuario
        WHERE t.TokenHash = @TokenHashActual;

        IF @IDToken IS NULL
            THROW 50111, N'Refresh token inválido.', 1;

        IF @Revocado IS NOT NULL
        BEGIN
            UPDATE RefreshTokens
            SET FechaRevocacion = SYSUTCDATETIME()
            WHERE IDUsuario = @IDUsuario AND FechaRevocacion IS NULL;
            COMMIT TRANSACTION;
            THROW 50112, N'Se detectó reutilización de un token. Todas las sesiones fueron cerradas.', 1;
        END;

        IF @Expira <= SYSUTCDATETIME()
            THROW 50113, N'El refresh token expiró.', 1;

        IF @UsuarioActivo = 0
            THROW 50114, N'El usuario está desactivado.', 1;

        -- Primero se revoca el actual (libera el índice único del dispositivo)
        UPDATE RefreshTokens SET FechaRevocacion = SYSUTCDATETIME() WHERE IDToken = @IDToken;

        INSERT INTO RefreshTokens (IDUsuario, TokenHash, FechaExpiracion, DispositivoID, DireccionIP)
        VALUES (@IDUsuario, @TokenHashNuevo, @FechaExpiracionNueva, @Dispositivo, @DireccionIP);
        SET @IDTokenNuevo = SCOPE_IDENTITY();

        UPDATE RefreshTokens SET IDTokenReemplazo = @IDTokenNuevo WHERE IDToken = @IDToken;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT u.IDUsuario, u.Email, u.NombreCompleto, r.NombreRol
    FROM Usuarios u
    JOIN Roles r ON r.IDRol = u.IDRol
    WHERE u.IDUsuario = @IDUsuario;
END;
GO

CREATE OR ALTER PROCEDURE SP_Auth_RevocarRefreshToken
    @TokenHash CHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE RefreshTokens
    SET FechaRevocacion = SYSUTCDATETIME()
    WHERE TokenHash = @TokenHash AND FechaRevocacion IS NULL;
END;
GO

------------------------------------------------------------------
-- Usuarios (Administrador)
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE SP_Usuarios_Crear
    @Email           NVARCHAR(150),
    @NombreCompleto  NVARCHAR(150),
    @PasswordHash    VARCHAR(255),
    @NombreRol       NVARCHAR(50),
    @IDUsuarioAccion INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    DECLARE @IDRol INT = (SELECT IDRol FROM Roles WHERE NombreRol = @NombreRol);
    IF @IDRol IS NULL
        THROW 50106, N'El rol indicado no existe.', 1;

    DECLARE @IDUsuario INT, @Json NVARCHAR(MAX);

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO Usuarios (Email, NombreCompleto, PasswordHash, IDRol)
        VALUES (LOWER(LTRIM(RTRIM(@Email))), LTRIM(RTRIM(@NombreCompleto)), @PasswordHash, @IDRol);
        SET @IDUsuario = SCOPE_IDENTITY();

        SET @Json = (SELECT IDUsuario, Email, NombreCompleto, IDRol, Activo
                     FROM Usuarios WHERE IDUsuario = @IDUsuario
                     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Usuarios', 'Usuarios', @IDUsuario, 'CREAR', NULL, @Json;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() IN (2601, 2627)
            THROW 50101, N'El correo ya está registrado.', 1;
        THROW;
    END CATCH;

    SELECT @IDUsuario AS IDUsuario;
END;
GO

-- Desactiva o reactiva un usuario sin borrarlo; al desactivar se cierran sus sesiones.
CREATE OR ALTER PROCEDURE SP_Usuarios_CambiarEstado
    @IDUsuario       INT,
    @Activo          BIT,
    @IDUsuarioAccion INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    IF NOT EXISTS (SELECT 1 FROM Usuarios WHERE IDUsuario = @IDUsuario)
        THROW 50104, N'El usuario no existe.', 1;

    IF @IDUsuario = @IDUsuarioAccion AND @Activo = 0
        THROW 50105, N'No puede desactivar su propio usuario.', 1;

    DECLARE @Antes NVARCHAR(MAX), @Despues NVARCHAR(MAX);
    DECLARE @Accion VARCHAR(15) = CASE WHEN @Activo = 0 THEN 'DESACTIVAR' ELSE 'MODIFICAR' END;

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @Antes = (SELECT IDUsuario, Email, Activo FROM Usuarios WHERE IDUsuario = @IDUsuario
                      FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        UPDATE Usuarios SET Activo = @Activo WHERE IDUsuario = @IDUsuario;

        IF @Activo = 0
            UPDATE RefreshTokens SET FechaRevocacion = SYSUTCDATETIME()
            WHERE IDUsuario = @IDUsuario AND FechaRevocacion IS NULL;

        SET @Despues = (SELECT IDUsuario, Email, Activo FROM Usuarios WHERE IDUsuario = @IDUsuario
                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC SP_Bitacora_Registrar @IDUsuarioAccion, 'Usuarios', 'Usuarios', @IDUsuario,
             @Accion, @Antes, @Despues;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE SP_Usuarios_Listar
    @IDUsuarioAccion INT,
    @Buscar          NVARCHAR(100) = NULL,
    @NombreRol       NVARCHAR(50)  = NULL,
    @Activo          BIT           = NULL,
    @Pagina          INT           = 1,
    @TamanoPagina    INT           = 20
AS
BEGIN
    SET NOCOUNT ON;
    EXEC SP_Usuarios_ExigirRol @IDUsuarioAccion, 'ADMIN';

    SET @Pagina = CASE WHEN @Pagina IS NULL OR @Pagina < 1 THEN 1 ELSE @Pagina END;
    SET @TamanoPagina = CASE WHEN @TamanoPagina IS NULL OR @TamanoPagina < 1 THEN 20
                             WHEN @TamanoPagina > 100 THEN 100 ELSE @TamanoPagina END;

    DECLARE @Patron NVARCHAR(220) = NULL;
    IF @Buscar IS NOT NULL AND LEN(LTRIM(RTRIM(@Buscar))) > 0
        SET @Patron = N'%' + REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Buscar)),
                      N'\', N'\\'), N'%', N'\%'), N'_', N'\_'), N'[', N'\[') + N'%';

    SELECT u.IDUsuario, u.Email, u.NombreCompleto, r.NombreRol, u.Activo, u.FechaCreacion,
           COUNT(*) OVER() AS TotalRegistros
    FROM Usuarios u
    JOIN Roles r ON r.IDRol = u.IDRol
    WHERE (@Patron IS NULL OR u.Email LIKE @Patron ESCAPE N'\' OR u.NombreCompleto LIKE @Patron ESCAPE N'\')
      AND (@NombreRol IS NULL OR r.NombreRol = @NombreRol)
      AND (@Activo IS NULL OR u.Activo = @Activo)
    ORDER BY u.NombreCompleto, u.IDUsuario
    OFFSET (@Pagina - 1) * @TamanoPagina ROWS FETCH NEXT @TamanoPagina ROWS ONLY;
END;
GO

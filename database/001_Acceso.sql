-- 001_Acceso.sql
-- Módulo de acceso: roles, usuarios y refresh tokens.

CREATE TABLE Roles (
    IDRol     INT IDENTITY(1,1) NOT NULL,
    NombreRol NVARCHAR(50)      NOT NULL,
    CONSTRAINT PK_Roles PRIMARY KEY (IDRol),
    CONSTRAINT UQ_Roles_NombreRol UNIQUE (NombreRol)
);
GO

CREATE TABLE Usuarios (
    IDUsuario     INT IDENTITY(1,1) NOT NULL,
    Email         NVARCHAR(150)     NOT NULL,
    NombreCompleto NVARCHAR(150)    NOT NULL,
    PasswordHash  VARCHAR(255)      NOT NULL,
    IDRol         INT               NOT NULL,
    Activo        BIT               NOT NULL CONSTRAINT DF_Usuarios_Activo DEFAULT 1,
    FechaCreacion DATETIME2(0)      NOT NULL CONSTRAINT DF_Usuarios_FechaCreacion DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Usuarios PRIMARY KEY (IDUsuario),
    CONSTRAINT UQ_Usuarios_Email UNIQUE (Email),
    CONSTRAINT CK_Usuarios_Email CHECK (Email LIKE '%_@_%._%'),
    CONSTRAINT FK_Usuarios_Roles FOREIGN KEY (IDRol) REFERENCES Roles (IDRol)
);
GO

CREATE INDEX IX_Usuarios_IDRol ON Usuarios (IDRol);
GO

CREATE TABLE RefreshTokens (
    IDToken           INT IDENTITY(1,1) NOT NULL,
    IDUsuario         INT               NOT NULL,
    TokenHash         CHAR(64)          NOT NULL,   -- SHA-256 en hexadecimal
    FechaCreacion     DATETIME2(0)      NOT NULL CONSTRAINT DF_RefreshTokens_FechaCreacion DEFAULT SYSUTCDATETIME(),
    FechaExpiracion   DATETIME2(0)      NOT NULL,
    FechaRevocacion   DATETIME2(0)      NULL,
    IDTokenReemplazo  INT               NULL,       -- token que lo reemplazó en la rotación
    DispositivoID     UNIQUEIDENTIFIER  NULL,
    DireccionIP       VARCHAR(45)       NULL,
    CONSTRAINT PK_RefreshTokens PRIMARY KEY (IDToken),
    CONSTRAINT UQ_RefreshTokens_TokenHash UNIQUE (TokenHash),
    CONSTRAINT FK_RefreshTokens_Usuarios FOREIGN KEY (IDUsuario) REFERENCES Usuarios (IDUsuario),
    CONSTRAINT FK_RefreshTokens_Reemplazo FOREIGN KEY (IDTokenReemplazo) REFERENCES RefreshTokens (IDToken),
    CONSTRAINT CK_RefreshTokens_Expiracion CHECK (FechaExpiracion > FechaCreacion),
    CONSTRAINT CK_RefreshTokens_NoSiMismo CHECK (IDTokenReemplazo IS NULL OR IDTokenReemplazo <> IDToken)
);
GO

CREATE INDEX IX_RefreshTokens_IDUsuario ON RefreshTokens (IDUsuario);
GO

-- Solo un token activo por usuario y dispositivo (los revocados no cuentan)
CREATE UNIQUE INDEX UX_RefreshTokens_DispositivoActivo
    ON RefreshTokens (IDUsuario, DispositivoID)
    WHERE FechaRevocacion IS NULL AND DispositivoID IS NOT NULL;
GO

-- Semillas de roles
INSERT INTO Roles (NombreRol) VALUES (N'Cliente'), (N'Operador'), (N'Administrador');
GO

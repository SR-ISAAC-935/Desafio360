-- 005_Semillas.sql
-- Datos de prueba reproducibles. Contraseña de los tres usuarios: Prueba123!
-- (hash bcrypt, costo 10; si el backend usa otro algoritmo, hay que regenerarlo)

-- Usuarios (los roles ya se sembraron en 001)
INSERT INTO Usuarios (Email, NombreCompleto, PasswordHash, IDRol)
SELECT v.Email, v.Nombre, '$2b$10$Ailom9WojMktAMpW1OrMnOGqU3mOCvD1eypu/FH.U6voXEjmNLaNO', r.IDRol
FROM (VALUES
    (N'admin@shopcart.test',    N'Administrador ShopCart', N'Administrador'),
    (N'operador@shopcart.test', N'Operador ShopCart',      N'Operador'),
    (N'cliente@shopcart.test',  N'Cliente de Prueba',      N'Cliente')
) AS v (Email, Nombre, Rol)
JOIN Roles r ON r.NombreRol = v.Rol;
GO

INSERT INTO Direcciones (IDUsuario, Direccion, Zona, Municipio, Departamento, Referencia)
SELECT IDUsuario, N'5a avenida 10-20', N'1', N'Guatemala', N'Guatemala', N'Casa blanca, portón negro'
FROM Usuarios WHERE Email = N'cliente@shopcart.test';
GO

-- Categorías
INSERT INTO Categorias (NombreCategoria, Descripcion) VALUES
    (N'Ropa',        N'Camisas, pantalones y prendas de vestir'),
    (N'Calzado',     N'Zapatos y tenis'),
    (N'Accesorios',  N'Gorras, mochilas y cinturones'),
    (N'Electrónica', N'Audífonos y dispositivos');
GO

-- Productos
INSERT INTO Productos (NombreProducto, IDCategoria, Descripcion)
SELECT v.Nombre, c.IDCategoria, v.Descripcion
FROM (VALUES
    (N'Camisa Polo',        N'Ropa',        N'Camisa polo de algodón'),
    (N'Pantalón Jeans',     N'Ropa',        N'Jeans corte recto'),
    (N'Sudadera con capucha', N'Ropa',      N'Sudadera de felpa'),
    (N'Tenis Running',      N'Calzado',     N'Tenis ligeros para correr'),
    (N'Zapato Casual',      N'Calzado',     N'Zapato de cuero casual'),
    (N'Gorra Clásica',      N'Accesorios',  N'Gorra ajustable'),
    (N'Mochila Urbana',     N'Accesorios',  N'Mochila para laptop de 15 pulgadas'),
    (N'Audífonos Bluetooth', N'Electrónica', N'Audífonos inalámbricos'),
    (N'Cargador Rápido',    N'Electrónica', N'Cargador USB-C de 30 W')
) AS v (Nombre, Categoria, Descripcion)
JOIN Categorias c ON c.NombreCategoria = v.Categoria;
GO

-- Variantes (existencia inicial; el kardex se genera abajo con el mismo valor)
INSERT INTO VariantesProducto (IDProducto, SKU, Talla, Color, Precio, ExistenciaFisica)
SELECT p.IDProducto, v.SKU, v.Talla, v.Color, v.Precio, v.Existencia
FROM (VALUES
    (N'Camisa Polo',    'POLO-M-AZ',  N'M',  N'Azul',   149.00, 50),
    (N'Camisa Polo',    'POLO-L-AZ',  N'L',  N'Azul',   149.00, 40),
    (N'Camisa Polo',    'POLO-M-BL',  N'M',  N'Blanco', 149.00, 30),
    (N'Camisa Polo',    'POLO-L-BL',  N'L',  N'Blanco', 149.00, 1),
    (N'Pantalón Jeans', 'JEAN-30-AZ', N'30', N'Azul',   249.00, 25),
    (N'Pantalón Jeans', 'JEAN-32-AZ', N'32', N'Azul',   249.00, 25),
    (N'Pantalón Jeans', 'JEAN-34-NG', N'34', N'Negro',  259.00, 20),
    (N'Sudadera con capucha', 'SUD-M-GR', N'M', N'Gris',  199.00, 35),
    (N'Sudadera con capucha', 'SUD-L-GR', N'L', N'Gris',  199.00, 35),
    (N'Tenis Running',  'TEN-40-NG',  N'40', N'Negro',  399.00, 15),
    (N'Tenis Running',  'TEN-42-NG',  N'42', N'Negro',  399.00, 15),
    (N'Tenis Running',  'TEN-42-BL',  N'42', N'Blanco', 399.00, 12),
    (N'Zapato Casual',  'ZAP-41-CF',  N'41', N'Café',   449.00, 10),
    (N'Zapato Casual',  'ZAP-43-CF',  N'43', N'Café',   449.00, 10),
    (N'Gorra Clásica',  'GOR-U-NG',   NULL,  N'Negro',   75.00, 100),
    (N'Gorra Clásica',  'GOR-U-RJ',   NULL,  N'Rojo',    75.00, 80),
    (N'Mochila Urbana', 'MOC-U-GR',   NULL,  N'Gris',   299.00, 22),
    (N'Audífonos Bluetooth', 'AUD-BT-NG', NULL, N'Negro', 349.00, 18),
    (N'Cargador Rápido', 'CAR-30W',   NULL,  N'Blanco',  99.00, 60)
) AS v (Producto, SKU, Talla, Color, Precio, Existencia)
JOIN Productos p ON p.NombreProducto = v.Producto;
GO

-- Kardex: entrada inicial por cada variante, así existencia = suma del kardex
INSERT INTO MovimientosInventario (IDVariante, IDUsuario, TipoMovimiento, Cantidad, ExistenciaResultante, Motivo)
SELECT v.IDVariante,
       (SELECT IDUsuario FROM Usuarios WHERE Email = N'admin@shopcart.test'),
       'ENTRADA', v.ExistenciaFisica, v.ExistenciaFisica, N'Inventario inicial'
FROM VariantesProducto v
WHERE v.ExistenciaFisica > 0;
GO

-- Cupones
INSERT INTO Cupones (Codigo, Descripcion, Tipo, Valor, FechaInicio, FechaFin, MontoMinimo, LimiteUsosTotal, LimiteUsosPorCliente, IDCategoria)
VALUES
    ('BIENVENIDO10', N'10 % de descuento en todo el carrito', 'PORCENTAJE', 10,
     '2026-10-01', '2027-12-31', 100, 1000, 1, NULL),
    ('ENVIO25',      N'Q25 de descuento en compras desde Q200', 'MONTO_FIJO', 25,
     '2026-10-01', '2027-12-31', 200, 500, 2, NULL),
    ('ROPA15',       N'15 % solo en la categoría Ropa', 'PORCENTAJE', 15,
     '2026-10-01', '2027-12-31', 0, 300, 1, (SELECT IDCategoria FROM Categorias WHERE NombreCategoria = N'Ropa')),
    ('VENCIDO5',     N'Cupón vencido para pruebas', 'PORCENTAJE', 5,
     '2025-01-01', '2025-12-31', 0, 100, 1, NULL);
GO

-- Cupón agotado para pruebas
INSERT INTO Cupones (Codigo, Descripcion, Tipo, Valor, FechaInicio, FechaFin, MontoMinimo, LimiteUsosTotal, UsosActuales, LimiteUsosPorCliente)
VALUES ('AGOTADO20', N'Cupón agotado para pruebas', 'PORCENTAJE', 20, '2026-10-01', '2027-12-31', 0, 5, 5, 1);
GO

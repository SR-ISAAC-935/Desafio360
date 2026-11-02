import { ejecutarSP } from '../db/ejecutarSP';
import { P } from '../db/parametros';
import { tablaVariantes } from '../db/tvp';
import { AppError } from '../errors/AppError';
import type {
  ActualizarProductoDto,
  ActualizarVarianteDto,
  CambiarPrecioDto,
  CrearProductoDto,
  VarianteNuevaDto,
} from '../schemas/productos.schemas';

/** Crea el producto con todas sus variantes en una sola llamada (las variantes viajan como TVP). */
export async function crearProducto(idAdmin: number, datos: CrearProductoDto): Promise<{ IDProducto: number }> {
  const resultado = await ejecutarSP('SP_Productos_Crear', [
    P.nvarchar('NombreProducto', 150, datos.nombreProducto),
    P.int('IDCategoria', datos.idCategoria),
    P.nvarchar('Descripcion', 1000, datos.descripcion),
    P.tabla('Variantes', tablaVariantes(datos.variantes)),
    P.int('IDUsuarioAccion', idAdmin),
  ]);

  const fila = resultado.primera<{ IDProducto: number }>();
  if (!fila) throw new AppError(500, 'ERROR_INTERNO', 'No se pudo crear el producto.');
  return fila;
}

/** Desactivar un producto lo oculta de la tienda; los pedidos que ya lo incluyen no se tocan. */
export async function actualizarProducto(idAdmin: number, idProducto: number, datos: ActualizarProductoDto): Promise<void> {
  await ejecutarSP('SP_Productos_Actualizar', [
    P.int('IDProducto', idProducto),
    P.nvarchar('NombreProducto', 150, datos.nombreProducto),
    P.int('IDCategoria', datos.idCategoria),
    P.nvarchar('Descripcion', 1000, datos.descripcion),
    P.bit('Activo', datos.activo),
    P.int('IDUsuarioAccion', idAdmin),
  ]);
}

export async function crearVariante(idAdmin: number, idProducto: number, datos: VarianteNuevaDto): Promise<{ IDVariante: number }> {
  const resultado = await ejecutarSP('SP_Variantes_Crear', [
    P.int('IDProducto', idProducto),
    P.varchar('SKU', 50, datos.sku),
    P.nvarchar('Talla', 30, datos.talla),
    P.nvarchar('Color', 30, datos.color),
    P.decimal('Precio', datos.precio),
    P.int('ExistenciaInicial', datos.existenciaInicial),
    P.nvarchar('ImagenUrl', 255, datos.imagenUrl),
    P.int('IDUsuarioAccion', idAdmin),
  ]);

  const fila = resultado.primera<{ IDVariante: number }>();
  if (!fila) throw new AppError(500, 'ERROR_INTERNO', 'No se pudo crear la variante.');
  return fila;
}

/** No cambia precio ni existencia: tienen sus propios endpoints con registro en la bitácora y el kardex. */
export async function actualizarVariante(idAdmin: number, idVariante: number, datos: ActualizarVarianteDto): Promise<void> {
  await ejecutarSP('SP_Variantes_Actualizar', [
    P.int('IDVariante', idVariante),
    P.nvarchar('Talla', 30, datos.talla),
    P.nvarchar('Color', 30, datos.color),
    P.nvarchar('ImagenUrl', 255, datos.imagenUrl),
    P.bit('Activo', datos.activo),
    P.int('IDUsuarioAccion', idAdmin),
  ]);
}

/** El cambio de precio no altera pedidos ya hechos (el detalle del pedido congela el precio). */
export async function cambiarPrecio(idAdmin: number, idVariante: number, datos: CambiarPrecioDto): Promise<void> {
  await ejecutarSP('SP_Variantes_CambiarPrecio', [
    P.int('IDVariante', idVariante),
    P.decimal('PrecioNuevo', datos.precio),
    P.int('IDUsuarioAccion', idAdmin),
  ]);
}

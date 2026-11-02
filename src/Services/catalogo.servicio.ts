import { ejecutarSP, type Fila } from '../db/ejecutarSP';
import { P } from '../db/parametros';
import { AppError } from '../errors/AppError';
import type { BuscarCatalogoQuery } from '../schemas/catalogo.schemas';

export async function listarCategorias(soloActivas: boolean): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Categorias_Listar', [P.bit('SoloActivas', soloActivas)]);
  return resultado.filas<Fila>();
}

/** Búsqueda de la tienda: texto, categoría, rango de precio, disponibilidad, orden y paginación en el servidor. */
export async function buscarProductos(q: BuscarCatalogoQuery): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Catalogo_Buscar', [
    P.nvarchar('Texto', 100, q.texto),
    P.int('IDCategoria', q.categoria),
    P.decimal('PrecioMin', q.precioMin),
    P.decimal('PrecioMax', q.precioMax),
    P.bit('SoloDisponibles', q.soloDisponibles ?? false),
    P.varchar('Ordenar', 15, q.ordenar),
    P.int('Pagina', q.pagina),
    P.int('TamanoPagina', q.tamanoPagina),
  ]);
  return resultado.filas<Fila>();
}

/** Producto con sus variantes. El backoffice usa incluirInactivos = true. */
export async function obtenerProducto(idProducto: number, incluirInactivos = false): Promise<{ producto: Fila; variantes: Fila[] }> {
  const resultado = await ejecutarSP('SP_Catalogo_ObtenerProducto', [
    P.int('IDProducto', idProducto),
    P.bit('IncluirInactivos', incluirInactivos),
  ]);

  const producto = resultado.primera<Fila>(0);
  if (!producto) throw new AppError(404, 'PRODUCTO_NO_ENCONTRADO', 'El producto no existe.');

  return { producto, variantes: resultado.filas<Fila>(1) };
}

import { ejecutarSP } from '../db/ejecutarSP';
import { P } from '../db/parametros';
import { AppError } from '../errors/AppError';
import type { ActualizarCategoriaDto, CrearCategoriaDto } from '../schemas/categorias.schemas';

export async function crearCategoria(idAdmin: number, datos: CrearCategoriaDto): Promise<{ IDCategoria: number }> {
  const resultado = await ejecutarSP('SP_Categorias_Crear', [
    P.nvarchar('NombreCategoria', 100, datos.nombreCategoria),
    P.nvarchar('Descripcion', 500, datos.descripcion),
    P.int('IDUsuarioAccion', idAdmin),
  ]);

  const fila = resultado.primera<{ IDCategoria: number }>();
  if (!fila) throw new AppError(500, 'ERROR_INTERNO', 'No se pudo crear la categoría.');
  return fila;
}

export async function actualizarCategoria(idAdmin: number, idCategoria: number, datos: ActualizarCategoriaDto): Promise<void> {
  await ejecutarSP('SP_Categorias_Actualizar', [
    P.int('IDCategoria', idCategoria),
    P.nvarchar('NombreCategoria', 100, datos.nombreCategoria),
    P.nvarchar('Descripcion', 500, datos.descripcion),
    P.bit('Activo', datos.activo),
    P.int('IDUsuarioAccion', idAdmin),
  ]);
}

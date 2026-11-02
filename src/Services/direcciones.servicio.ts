import { ejecutarSP, type Fila } from '../db/ejecutarSP';
import { P } from '../db/parametros';
import { AppError } from '../errors/AppError';
import type { CrearDireccionDto } from '../schemas/direcciones.schemas';

/** Solo las direcciones del propio cliente: el id sale del token, no de la petición. */
export async function listarDirecciones(idUsuario: number): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Direcciones_Listar', [P.int('IDUsuario', idUsuario)]);
  return resultado.filas<Fila>();
}

export async function crearDireccion(idUsuario: number, datos: CrearDireccionDto): Promise<{ IDDireccion: number }> {
  const resultado = await ejecutarSP('SP_Direcciones_Crear', [
    P.int('IDUsuario', idUsuario),
    P.nvarchar('Direccion', 200, datos.direccion),
    P.nvarchar('Zona', 10, datos.zona),
    P.nvarchar('Municipio', 100, datos.municipio),
    P.nvarchar('Departamento', 100, datos.departamento),
    P.nvarchar('Referencia', 255, datos.referencia),
    P.varchar('CodigoPostal', 10, datos.codigoPostal),
  ]);

  const fila = resultado.primera<{ IDDireccion: number }>();
  if (!fila) throw new AppError(500, 'ERROR_INTERNO', 'No se pudo crear la dirección.');
  return fila;
}

/** No se borra: los pedidos anteriores siguen apuntando a ella. Responde 403 si no es del cliente. */
export async function desactivarDireccion(idUsuario: number, idDireccion: number): Promise<void> {
  await ejecutarSP('SP_Direcciones_Desactivar', [
    P.int('IDDireccion', idDireccion),
    P.int('IDUsuario', idUsuario),
  ]);
}

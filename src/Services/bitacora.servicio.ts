import { ejecutarSP, type Fila } from '../db/ejecutarSP';
import { P } from '../db/parametros';
import type { BitacoraQuery } from '../schemas/bitacora.schemas';

/** La bitácora solo se consulta: no existe ningún procedimiento ni endpoint para modificarla o borrarla. */
export async function listarBitacora(idAdmin: number, q: BitacoraQuery): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Bitacora_Listar', [
    P.int('IDUsuarioAccion', idAdmin),
    P.varchar('Modulo', 30, q.modulo),
    P.fecha('Desde', q.desde),
    P.fecha('Hasta', q.hasta),
    P.int('Pagina', q.pagina),
    P.int('TamanoPagina', q.tamanoPagina),
  ]);
  return resultado.filas<Fila>();
}

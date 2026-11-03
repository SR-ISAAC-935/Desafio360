import { ejecutarSP, type Fila } from '../db/ejecutarSP';
import { P } from '../db/parametros';
import { tablaEntradas } from '../db/tvp';
import type { AjusteDto, EntradasDto, ExistenciasQuery, KardexQuery } from '../schemas/inventario.schemas';

export async function listarExistencias(idUsuario: number, q: ExistenciasQuery): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Inventario_ListarExistencias', [
    P.int('IDUsuarioAccion', idUsuario),
    P.nvarchar('Texto', 100, q.texto),
    P.int('IDCategoria', q.categoria),
    P.int('Pagina', q.pagina),
    P.int('TamanoPagina', q.tamanoPagina),
  ]);
  return resultado.filas<Fila>();
}

export async function consultarKardex(idUsuario: number, idVariante: number, q: KardexQuery): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Inventario_ConsultarKardex', [
    P.int('IDVariante', idVariante),
    P.int('IDUsuarioAccion', idUsuario),
    P.fecha('Desde', q.desde),
    P.fecha('Hasta', q.hasta),
    P.int('Pagina', q.pagina),
    P.int('TamanoPagina', q.tamanoPagina),
  ]);
  return resultado.filas<Fila>();
}

/** Entrada por compra o ajuste manual. Exige motivo y nunca deja la existencia en negativo. */
export async function ajustarExistencia(idUsuario: number, datos: AjusteDto): Promise<Fila | undefined> {
  const resultado = await ejecutarSP('SP_Inventario_AjustarExistencia', [
    P.int('IDVariante', datos.idVariante),
    P.varchar('TipoMovimiento', 20, datos.tipo),
    P.int('Cantidad', datos.cantidad),
    P.nvarchar('Motivo', 255, datos.motivo),
    P.int('IDUsuarioAccion', idUsuario),
  ]);
  return resultado.primera<Fila>();
}

/** Entradas de varias variantes a la vez: las líneas viajan como TVP. */
export async function registrarEntradas(idUsuario: number, datos: EntradasDto): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Inventario_RegistrarEntradas', [
    P.tabla('Entradas', tablaEntradas(datos.entradas)),
    P.nvarchar('Motivo', 255, datos.motivo),
    P.int('IDUsuarioAccion', idUsuario),
  ]);
  return resultado.filas<Fila>();
}

/** Verifica que la existencia coincida con la suma del kardex. Una lista vacía significa que todo cuadra. */
export async function verificarKardex(): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Inventario_VerificarKardex');
  return resultado.filas<Fila>();
}

/** Mantenimiento: marca como vencidas las reservas que pasaron de 15 minutos. La disponibilidad ya las ignora sola. */
export async function liberarReservasVencidas(): Promise<{ reservasLiberadas: number }> {
  const resultado = await ejecutarSP('SP_Inventario_LiberarReservasVencidas');
  const fila = resultado.primera<{ ReservasLiberadas: number }>();
  return { reservasLiberadas: fila?.ReservasLiberadas ?? 0 };
}

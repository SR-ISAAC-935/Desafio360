import { ejecutarSP, type Fila } from '../db/ejecutarSP';
import { P, type Param } from '../db/parametros';
import type { AbandonadosQuery, RangoQuery, ResumenQuery, TopProductosQuery, VentasQuery } from '../schemas/reportes.schemas';

const rango = (idAdmin: number, q: RangoQuery): Param[] => [
  P.int('IDUsuarioAccion', idAdmin),
  P.fecha('Desde', q.desde),
  P.fecha('Hasta', q.hasta),
];

/** Los reportes solo cuentan pedidos completados (sin cancelados ni devueltos) y descuentan devoluciones parciales. */
export async function ventasPorPeriodo(idAdmin: number, q: VentasQuery): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Reportes_VentasPorPeriodo', [
    ...rango(idAdmin, q),
    P.varchar('Agrupacion', 10, q.agrupacion),
  ]);
  return resultado.filas<Fila>();
}

export async function ventasPorCategoria(idAdmin: number, q: RangoQuery): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Reportes_VentasPorCategoria', rango(idAdmin, q));
  return resultado.filas<Fila>();
}

export async function topProductos(idAdmin: number, q: TopProductosQuery): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Reportes_TopProductos', [...rango(idAdmin, q), P.int('Top', q.top)]);
  return resultado.filas<Fila>();
}

/** Indicadores del periodo (pedidos, total vendido, ticket promedio) y carritos abandonados. */
export async function resumen(idAdmin: number, q: ResumenQuery): Promise<{ indicadores: Fila | undefined; carritosAbandonados: number }> {
  const resultado = await ejecutarSP('SP_Reportes_Resumen', [
    ...rango(idAdmin, q),
    P.int('MinutosInactividad', q.minutosInactividad),
  ]);
  const abandonados = resultado.primera<{ CarritosAbandonados: number }>(1);
  return {
    indicadores: resultado.primera<Fila>(0),
    carritosAbandonados: abandonados?.CarritosAbandonados ?? 0,
  };
}

export async function carritosAbandonados(idAdmin: number, q: AbandonadosQuery): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Reportes_CarritosAbandonados', [
    P.int('IDUsuarioAccion', idAdmin),
    P.int('MinutosInactividad', q.minutosInactividad),
    P.int('Pagina', q.pagina),
    P.int('TamanoPagina', q.tamanoPagina),
  ]);
  return resultado.filas<Fila>();
}

import type { Fila } from '../db/ejecutarSP';

export interface Pagina {
  datos: Fila[];
  total: number;
  pagina: number;
  tamanoPagina: number;
  totalPaginas: number;
}

/**
 * Los listados paginados de la base devuelven la columna TotalRegistros en cada fila.
 * Aquí se separa: las filas quedan limpias y el total pasa al encabezado de la respuesta.
 */
export function armarPagina(filas: Fila[], pagina: number, tamanoPagina: number): Pagina {
  const total = Number(filas[0]?.['TotalRegistros'] ?? 0);
  const datos = filas.map(({ TotalRegistros: _total, ...resto }) => resto);
  return {
    datos,
    total,
    pagina,
    tamanoPagina,
    totalPaginas: total === 0 ? 0 : Math.ceil(total / tamanoPagina),
  };
}

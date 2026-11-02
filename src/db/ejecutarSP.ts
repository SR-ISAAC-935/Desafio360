import sql from 'mssql';
import { obtenerPool } from './pool';
import type { Param } from './parametros';
import { esDeadlock, traducirErrorSql } from '../errors/errorSql';

/** Fila devuelta por un procedimiento: columnas desconocidas hasta que el servicio las tipa. */
export type Fila = Record<string, unknown>;

/** Resultado de un procedimiento: uno o varios conjuntos de filas (recordsets). */
export class ResultadoSP {
  constructor(private readonly recordsets: readonly (readonly Fila[])[]) {}

  /** Filas de un conjunto de resultados (el primero por defecto). Ej: r.filas<Producto>(0) */
  filas<T>(indice = 0): T[] {
    return [...(this.recordsets[indice] ?? [])] as unknown as T[];
  }

  /** Primera fila de un conjunto de resultados, o undefined si está vacío. */
  primera<T>(indice = 0): T | undefined {
    return this.filas<T>(indice)[0];
  }

  get cantidadConjuntos(): number {
    return this.recordsets.length;
  }
}

const MAX_INTENTOS = 3;
const esperar = (ms: number): Promise<void> => new Promise((resolver) => setTimeout(resolver, ms));

async function ejecutarUnaVez(nombre: string, parametros: readonly Param[]): Promise<ResultadoSP> {
  const pool = await obtenerPool();
  const peticion = pool.request();

  for (const parametro of parametros) {
    if (parametro.valor instanceof sql.Table) {
      peticion.input(parametro.nombre, parametro.valor);
    } else if (parametro.tipo) {
      peticion.input(parametro.nombre, parametro.tipo, parametro.valor);
    } else {
      throw new Error(`El parámetro ${parametro.nombre} necesita un tipo`);
    }
  }

  const resultado = await peticion.execute(nombre);
  return new ResultadoSP(resultado.recordsets as unknown as Fila[][]);
}

/**
 * Ejecuta un stored procedure con parámetros tipados.
 *  - Reintenta si SQL Server elige la solicitud como víctima de un deadlock (1205).
 *  - Traduce cualquier error de SQL a un AppError (la tabla está en errors/errorSql.ts).
 */
export async function ejecutarSP(nombre: string, parametros: readonly Param[] = []): Promise<ResultadoSP> {
  for (let intento = 1; ; intento++) {
    try {
      return await ejecutarUnaVez(nombre, parametros);
    } catch (error: unknown) {
      if (esDeadlock(error) && intento < MAX_INTENTOS) {
        await esperar(40 * intento * intento + Math.floor(Math.random() * 40));
        continue;
      }
      throw traducirErrorSql(error);
    }
  }
}

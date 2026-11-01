import sql from 'mssql';

/**
 * Un parámetro tipado de un procedimiento. SIEMPRE se envía como parámetro (nunca se concatena
 * en una cadena SQL), y el tipo se declara de forma explícita igual que en el procedimiento.
 */
export interface Param {
  nombre: string; // sin el @
  tipo?: sql.ISqlType | (() => sql.ISqlType); // se omite solo para tablas (TVP)
  valor: unknown;
}

/** 'YYYY-MM-DD' -> Date en UTC (las fechas de la base se guardan y comparan en UTC). */
function aFecha(valor: string | Date): Date {
  return typeof valor === 'string' ? new Date(`${valor}T00:00:00.000Z`) : valor;
}

/** Constructores de parámetros: P.int('IDUsuario', 5), P.nvarchar('Email', 150, correo), ... */
export const P = {
  int: (nombre: string, valor?: number | null): Param => ({ nombre, tipo: sql.Int, valor: valor ?? null }),

  bit: (nombre: string, valor?: boolean | null): Param => ({ nombre, tipo: sql.Bit, valor: valor ?? null }),

  nvarchar: (nombre: string, tamano: number, valor?: string | null): Param => ({
    nombre,
    tipo: sql.NVarChar(tamano),
    valor: valor ?? null,
  }),

  varchar: (nombre: string, tamano: number, valor?: string | null): Param => ({
    nombre,
    tipo: sql.VarChar(tamano),
    valor: valor ?? null,
  }),

  char: (nombre: string, tamano: number, valor?: string | null): Param => ({
    nombre,
    tipo: sql.Char(tamano),
    valor: valor ?? null,
  }),

  /** DECIMAL(18,2), el tipo de todos los montos. La API debe validar máximo 2 decimales. */
  decimal: (nombre: string, valor?: number | null): Param => ({
    nombre,
    tipo: sql.Decimal(18, 2),
    valor: valor ?? null,
  }),

  fecha: (nombre: string, valor?: string | Date | null): Param => ({
    nombre,
    tipo: sql.Date,
    valor: valor == null ? null : aFecha(valor),
  }),

  fechaHora: (nombre: string, valor?: string | Date | null): Param => ({
    nombre,
    tipo: sql.DateTime2(0),
    valor: valor == null ? null : new Date(valor),
  }),

  guid: (nombre: string, valor?: string | null): Param => ({
    nombre,
    tipo: sql.UniqueIdentifier,
    valor: valor ?? null,
  }),

  /** Parámetro con valores de tabla (TVP). Ver crearTabla() en db/tvp.ts. */
  tabla: (nombre: string, valor: sql.Table): Param => ({ nombre, valor }),
};

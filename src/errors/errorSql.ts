import sql from 'mssql';
import { AppError } from './AppError';

/**
 * Códigos que lanzan los procedimientos con THROW (ver el catálogo al inicio de 008_SP_Acceso.sql)
 * y el estado HTTP con el que se responden. El mensaje en español viene del propio THROW.
 */
const ESTADO_HTTP_POR_CODIGO_SQL: Readonly<Record<number, number>> = {
  50001: 409, 50002: 403, 50003: 403,
  50101: 409, 50103: 403, 50104: 404, 50105: 409, 50106: 400,
  50111: 401, 50112: 401, 50113: 401, 50114: 403,
  50121: 409, 50122: 400, 50123: 404, 50124: 404, 50125: 400, 50126: 400,
  50131: 409, 50132: 409, 50133: 400, 50134: 400, 50135: 400,
  50141: 404, 50142: 403, 50143: 409, 50144: 409, 50145: 409, 50146: 404, 50147: 400,
  50151: 404, 50152: 409, 50153: 409, 50154: 409, 50155: 409, 50156: 409, 50157: 409, 50158: 409, 50159: 401,
  50161: 409, 50162: 400, 50163: 404,
  50171: 409, 50172: 409, 50173: 400, 50174: 409, 50175: 409,
  50181: 400, 50182: 403, 50183: 403, 50184: 404,
  50190: 503, 50191: 400, 50192: 409, 50193: 400, 50199: 500,
  50201: 409, 50202: 400, 50203: 409, 50204: 400,
  50211: 400,
};

const CODIGOS_CONEXION = new Set(['ELOGIN', 'ETIMEOUT', 'ESOCKET', 'ECONNCLOSED', 'ECONNRESET', 'ENOTOPEN', 'ECONNREFUSED']);

/** Lee el número de error de SQL Server (o de tedious) sin asumir la forma exacta del error. */
export function numeroErrorSql(error: unknown): number | undefined {
  if (typeof error !== 'object' || error === null) return undefined;

  const directo = (error as { number?: unknown }).number;
  if (typeof directo === 'number') return directo;

  const original = (error as { originalError?: unknown }).originalError;
  if (typeof original === 'object' && original !== null) {
    const interno = (original as { number?: unknown }).number;
    if (typeof interno === 'number') return interno;
  }
  return undefined;
}

function codigoNodo(error: unknown): string | undefined {
  if (typeof error !== 'object' || error === null) return undefined;
  const codigo = (error as { code?: unknown }).code;
  return typeof codigo === 'string' ? codigo : undefined;
}

/** Un deadlock (1205) es seguro de reintentar: SQL Server ya deshizo la transacción. */
export function esDeadlock(error: unknown): boolean {
  return numeroErrorSql(error) === 1205;
}

/** Convierte cualquier error de la capa de datos en un AppError con el HTTP correcto. */
export function traducirErrorSql(error: unknown): AppError {
  if (error instanceof AppError) return error;

  const numero = numeroErrorSql(error);

  if (numero !== undefined) {
    const estado = ESTADO_HTTP_POR_CODIGO_SQL[numero];
    if (estado !== undefined && error instanceof Error) {
      return new AppError(estado, `SQL_${numero}`, error.message);
    }
    if (numero === 1205) {
      return new AppError(503, 'CONFLICTO_CONCURRENCIA', 'El sistema está ocupado. Intente de nuevo en unos segundos.');
    }
    if (numero === 1222) {
      return new AppError(503, 'BLOQUEO_AGOTADO', 'El recurso está en uso. Intente de nuevo en unos segundos.');
    }
    if (numero === 547) {
      return new AppError(400, 'DATOS_INVALIDOS', 'Los datos enviados no cumplen las reglas de integridad.');
    }
    if (numero === 2601 || numero === 2627) {
      return new AppError(409, 'REGISTRO_DUPLICADO', 'Ya existe un registro con esos datos.');
    }
    if (numero === 8115 || numero === 8152 || numero === 2628) {
      return new AppError(400, 'DATOS_FUERA_DE_RANGO', 'Un dato enviado excede el tamaño o rango permitido.');
    }
  }

  const codigo = codigoNodo(error);
  if (error instanceof sql.ConnectionError || (codigo !== undefined && CODIGOS_CONEXION.has(codigo))) {
    console.error('Problema de conexión con SQL Server:', error);
    return new AppError(503, 'BD_NO_DISPONIBLE', 'El servicio no está disponible en este momento.');
  }

  console.error('Error inesperado en la capa de datos:', error);
  return new AppError(500, 'ERROR_INTERNO', 'Ocurrió un error interno. Intente de nuevo más tarde.');
}

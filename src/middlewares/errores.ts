import type { ErrorRequestHandler, RequestHandler } from 'express';
import { ZodError } from 'zod';
import { AppError } from '../errors/AppError';

interface CuerpoError {
  error: { codigo: string; mensaje: string; detalles?: unknown };
}

const cuerpo = (codigo: string, mensaje: string, detalles?: unknown): CuerpoError => ({
  error: detalles === undefined ? { codigo, mensaje } : { codigo, mensaje, detalles },
});

/** Errores que genera Express al leer el body (JSON mal formado, cuerpo demasiado grande). */
function esErrorDeCuerpo(error: unknown): error is { status: number; type: string } {
  if (typeof error !== 'object' || error === null) return false;
  const { status, type } = error as { status?: unknown; type?: unknown };
  return typeof status === 'number' && typeof type === 'string' && status >= 400 && status < 500;
}

export const rutaNoEncontrada: RequestHandler = (_req, _res, next) => {
  next(new AppError(404, 'RUTA_NO_ENCONTRADA', 'La ruta solicitada no existe.'));
};

/**
 * Manejador central: TODA respuesta de error de la API sale de aquí con la misma forma:
 *   { "error": { "codigo": "...", "mensaje": "...", "detalles": ... } }
 * Nunca se devuelve el stack ni mensajes crudos de SQL Server.
 */
export const manejadorErrores: ErrorRequestHandler = (error: unknown, _req, res, next) => {
  if (res.headersSent) {
    next(error);
    return;
  }

  if (error instanceof AppError) {
    res.status(error.estado).json(cuerpo(error.codigo, error.message, error.detalles));
    return;
  }

  if (error instanceof ZodError) {
    const detalles = error.issues.map((problema) => ({
      campo: problema.path.join('.'),
      mensaje: problema.message,
    }));
    res.status(400).json(cuerpo('VALIDACION', 'Los datos enviados no son válidos.', detalles));
    return;
  }

  if (esErrorDeCuerpo(error)) {
    if (error.type === 'entity.too.large') {
      res.status(413).json(cuerpo('CUERPO_DEMASIADO_GRANDE', 'El cuerpo de la solicitud es demasiado grande.'));
      return;
    }
    res.status(400).json(cuerpo('SOLICITUD_INVALIDA', 'El cuerpo de la solicitud no es un JSON válido.'));
    return;
  }

  console.error('Error no controlado:', error);
  res.status(500).json(cuerpo('ERROR_INTERNO', 'Ocurrió un error interno. Intente de nuevo más tarde.'));
};

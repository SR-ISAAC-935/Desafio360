import type { Request } from 'express';
import { AppError } from '../errors/AppError';
import type { UsuarioAutenticado } from '../servicios/tokens.servicio';

/**
 * Usuario que hace la petición, tomado SIEMPRE del token ya verificado (req.usuario),
 * nunca del body, de la URL ni del query. Lanza 401 si la ruta olvidó usar "autenticar".
 */
export function usuarioDe(req: Request): UsuarioAutenticado {
  if (!req.usuario) {
    throw new AppError(401, 'NO_AUTENTICADO', 'Falta el token de acceso.');
  }
  return req.usuario;
}

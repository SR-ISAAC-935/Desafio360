import type { RequestHandler } from 'express';
import { AppError } from '../errors/AppError';
import { verificarAccessToken, type RolNombre } from '../Services/tokens.servicio';

/**
 * Exige un access token válido en la cabecera "Authorization: Bearer <token>".
 * Si es correcto deja al usuario en req.usuario; si no, responde 401.
 */
export const autenticar: RequestHandler = (req, _res, next) => {
  const cabecera = req.header('authorization');

  if (!cabecera || !cabecera.startsWith('Bearer ')) {
    throw new AppError(401, 'NO_AUTENTICADO', 'Falta el token de acceso.');
  }

  req.usuario = verificarAccessToken(cabecera.slice('Bearer '.length).trim());
  next();
};

/**
 * Permite el paso solo a los roles indicados; el resto recibe 403.
 * Debe usarse DESPUÉS de "autenticar": exigirRol('Administrador'), exigirRol('Operador', 'Administrador').
 */
export const exigirRol =
  (...rolesPermitidos: RolNombre[]): RequestHandler =>
  (req, _res, next) => {
    if (!req.usuario) {
      throw new AppError(401, 'NO_AUTENTICADO', 'Falta el token de acceso.');
    }
    if (!rolesPermitidos.includes(req.usuario.rol)) {
      throw new AppError(403, 'SIN_PERMISOS', 'No tiene permisos para realizar esta acción.');
    }
    next();
  };

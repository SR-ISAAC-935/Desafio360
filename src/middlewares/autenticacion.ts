import type { Request, RequestHandler } from 'express';
import { AppError } from '../errors/AppError';
import { verificarAccessToken, type RolNombre, type UsuarioAutenticado } from '../Services/tokens.servicio';

/** Lee y verifica "Authorization: Bearer <token>". Lanza 401 si falta, está mal formado, expiró o no es válido. */
function usuarioDelToken(req: Request): UsuarioAutenticado {
  const cabecera = req.header('authorization');

  if (!cabecera || !cabecera.startsWith('Bearer ')) {
    throw new AppError(401, 'NO_AUTENTICADO', 'Falta el token de acceso.');
  }
  return verificarAccessToken(cabecera.slice('Bearer '.length).trim());
}

/**
 * Exige un access token válido. Si es correcto deja al usuario en req.usuario; si no, responde 401.
 */
export const autenticar: RequestHandler = (req, _res, next) => {
  req.usuario = usuarioDelToken(req);
  next();
};

/**
 * Autenticación OPCIONAL, para rutas que sirven tanto a usuarios con sesión como a invitados (el carrito).
 *  - Sin cabecera Authorization: sigue como invitado (req.usuario queda vacío).
 *  - Con cabecera: debe ser válida. Si no lo es responde 401: nunca se "degrada" a invitado en silencio.
 */
export const autenticarOpcional: RequestHandler = (req, _res, next) => {
  if (req.header('authorization') !== undefined) {
    req.usuario = usuarioDelToken(req);
  }
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

/** Para el carrito: un invitado pasa; un usuario con sesión debe ser Cliente (Operador y Administrador no compran). */
export const exigirClienteOInvitado: RequestHandler = (req, _res, next) => {
  if (req.usuario && req.usuario.rol !== 'Cliente') {
    throw new AppError(403, 'SIN_PERMISOS', 'Solo los clientes pueden usar el carrito.');
  }
  next();
};

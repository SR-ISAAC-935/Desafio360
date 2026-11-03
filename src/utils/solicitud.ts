import type { Request } from 'express';
import { AppError } from '../errors/AppError';
import { CABECERA_TOKEN_CARRITO, tokenInvitadoSchema } from '../schemas/carrito.schemas';
import type { UsuarioAutenticado } from '../Services/tokens.servicio';

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

/** Quién es el dueño del carrito: un usuario con sesión o un invitado identificado por su token. */
export interface DuenoCarrito {
  idUsuario: number | null;
  tokenInvitado: string | null;
}

/**
 * Con sesión, el dueño es el usuario del token. Sin sesión, el dueño es el invitado que manda la cabecera
 * X-Carrito-Token (si no la manda todavía no tiene carrito). El cliente NUNCA envía un IDCarrito.
 */
export function duenoDelCarrito(req: Request): DuenoCarrito {
  if (req.usuario) {
    return { idUsuario: req.usuario.id, tokenInvitado: null };
  }

  const crudo = req.header(CABECERA_TOKEN_CARRITO);
  if (crudo === undefined) {
    return { idUsuario: null, tokenInvitado: null };
  }

  const token = tokenInvitadoSchema.safeParse(crudo.trim());
  if (!token.success) {
    throw new AppError(400, 'TOKEN_CARRITO_INVALIDO', 'El token del carrito no es válido.');
  }
  return { idUsuario: null, tokenInvitado: token.data };
}

/** Igual que duenoDelCarrito, pero para operaciones sobre un carrito que ya debe existir. */
export function duenoExistenteDelCarrito(req: Request): DuenoCarrito {
  const dueno = duenoDelCarrito(req);
  if (dueno.idUsuario === null && dueno.tokenInvitado === null) {
    throw new AppError(400, 'CARRITO_NO_IDENTIFICADO', 'Inicie sesión o envíe la cabecera X-Carrito-Token de su carrito.');
  }
  return dueno;
}

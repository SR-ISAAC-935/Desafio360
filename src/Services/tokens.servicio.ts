import { createHash, randomBytes } from 'node:crypto';
import jwt from 'jsonwebtoken';
import { env } from '../config/env';
import { AppError } from '../errors/AppError';

export const ROLES = ['Cliente', 'Operador', 'Administrador'] as const;
export type RolNombre = (typeof ROLES)[number];

/** Lo único que viaja dentro del access token y que el resto de la app puede usar. */
export interface UsuarioAutenticado {
  id: number;
  rol: RolNombre;
}

const ALGORITMO = 'HS256' as const;

function esRol(valor: unknown): valor is RolNombre {
  return typeof valor === 'string' && (ROLES as readonly string[]).includes(valor);
}

/** Firma un access token de corta duración. `expiresIn` va en segundos (número). */
export function crearAccessToken(usuario: { IDUsuario: number; NombreRol: string }): string {
  return jwt.sign({ rol: usuario.NombreRol }, env.JWT_SECRET, {
    subject: String(usuario.IDUsuario),
    algorithm: ALGORITMO,
    expiresIn: env.JWT_ACCESS_MINUTES * 60,
  });
}

/**
 * Verifica firma, algoritmo y expiración, y comprueba la forma del contenido.
 * Lanza AppError 401 (TOKEN_EXPIRADO o TOKEN_INVALIDO) si algo falla.
 */
export function verificarAccessToken(token: string): UsuarioAutenticado {
  let contenido: string | jwt.JwtPayload;
  try {
    contenido = jwt.verify(token, env.JWT_SECRET, { algorithms: [ALGORITMO] });
  } catch (error: unknown) {
    if (error instanceof jwt.TokenExpiredError) {
      throw new AppError(401, 'TOKEN_EXPIRADO', 'El token de acceso expiró. Renueve la sesión.');
    }
    throw new AppError(401, 'TOKEN_INVALIDO', 'El token de acceso no es válido.');
  }

  const id = typeof contenido === 'object' ? Number(contenido.sub) : NaN;
  const rol: unknown = typeof contenido === 'object' ? contenido['rol'] : undefined;

  if (!Number.isInteger(id) || id <= 0 || !esRol(rol)) {
    throw new AppError(401, 'TOKEN_INVALIDO', 'El token de acceso no es válido.');
  }
  return { id, rol };
}

/** SHA-256 en hexadecimal (64 caracteres): es lo único del refresh token que se guarda en la base. */
export function hashearToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

export interface RefreshTokenNuevo {
  token: string; // se entrega al cliente UNA vez y no se guarda
  hash: string; // se guarda en la base
  expiraEn: Date;
}

/** Refresh token opaco y aleatorio (no es un JWT). */
export function crearRefreshToken(): RefreshTokenNuevo {
  const token = randomBytes(48).toString('base64url');
  return {
    token,
    hash: hashearToken(token),
    expiraEn: new Date(Date.now() + env.REFRESH_TOKEN_DAYS * 24 * 60 * 60 * 1000),
  };
}

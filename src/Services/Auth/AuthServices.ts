import bcrypt from 'bcryptjs';
import { env } from '../../config/env';
import { ejecutarSP } from '../../db/ejecutarSP';
import { P } from '../../db/parametros';
import { AppError } from '../../errors/AppError';
import type { InicioSesionDto, RegistroDto } from '../../schemas/auth.schemas';
import jwt from 'jsonwebtoken';
import { createHash, randomBytes } from 'node:crypto';
interface UsuarioRow {
  IDUsuario: number; Email: string; NombreCompleto: string; PasswordHash: string;
  Activo: boolean; IDRol: number; NombreRol: string;
}
export type UsuarioPublico = Omit<UsuarioRow, 'PasswordHash'>;
export interface UsuarioRegistrado { IDUsuario: number; Email: string; NombreCompleto: string; NombreRol: string; }

// Si el correo no existe se compara contra este hash, para que el tiempo de respuesta no delate correos válidos.
const HASH_DE_RELLENO = bcrypt.hashSync('contrasena-que-nadie-usa', env.BCRYPT_ROUNDS);
const ALGORITMO = 'HS256' as const;
export async function registrarUsuario(datos: RegistroDto): Promise<UsuarioRegistrado> {
  const hash = await bcrypt.hash(datos.password, env.BCRYPT_ROUNDS);
  const resultado = await ejecutarSP('SP_Auth_RegistrarCliente', [
    P.nvarchar('Email', 150, datos.email),
    P.nvarchar('NombreCompleto', 150, datos.nombreCompleto),
    P.varchar('PasswordHash', 255, hash),
  ]);
  const usuario = resultado.primera<UsuarioRegistrado>();
  if (!usuario) throw new AppError(500, 'ERROR_INTERNO', 'No se pudo registrar el usuario.');
  return usuario;
}

export async function iniciarSesion(datos: InicioSesionDto, ip?: string) {
  const usuario = await validarCredenciales(datos);
  const refresh = crearRefreshToken();
  await ejecutarSP('SP_Auth_GuardarRefreshToken', [
    P.int('IDUsuario', usuario.IDUsuario),
    P.char('TokenHash', 64, refresh.hash),
    P.fechaHora('FechaExpiracion', refresh.expiraEn),
    P.varchar('DireccionIP', 45, ip),
  ]);
  return { usuario, accessToken: crearAccessToken(usuario), refreshToken: refresh.token };
}
export async function renovarSesion(refreshToken: string, ip?: string) {
  const nuevo = crearRefreshToken();
  const r = await ejecutarSP('SP_Auth_RotarRefreshToken', [
    P.char('TokenHashActual', 64, hashearToken(refreshToken)),
    P.char('TokenHashNuevo', 64, nuevo.hash),
    P.fechaHora('FechaExpiracionNueva', nuevo.expiraEn),
    P.varchar('DireccionIP', 45, ip),
  ]);
  const usuario = r.primera<{ IDUsuario: number; NombreRol: string }>();
  if (!usuario) throw new AppError(500, 'ERROR_INTERNO', 'No se pudo renovar la sesión.');
  return { accessToken: crearAccessToken(usuario), refreshToken: nuevo.token };
}

export async function cerrarSesion(refreshToken: string): Promise<void> {
  await ejecutarSP('SP_Auth_RevocarRefreshToken', [P.char('TokenHash', 64, hashearToken(refreshToken))]);
}
export async function validarCredenciales(datos: InicioSesionDto): Promise<UsuarioPublico> {
  const resultado = await ejecutarSP('SP_Auth_ObtenerUsuarioPorEmail', [P.nvarchar('Email', 150, datos.email)]);
  const usuario = resultado.primera<UsuarioRow>();

  const coincide = await bcrypt.compare(datos.password, usuario?.PasswordHash ?? HASH_DE_RELLENO);

  if (!usuario || !coincide || !usuario.Activo) {
    throw new AppError(401, 'CREDENCIALES_INVALIDAS', 'Correo o contraseña incorrectos.');
  }
  const { PasswordHash: _hash, ...publico } = usuario;
  return publico;
}

export interface RefreshTokenNuevo {
  token: string;   // se entrega al cliente UNA vez y no se guarda
  hash: string;    // se guarda en la base
  expiraEn: Date;
}
export function hashearToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}
export function crearRefreshToken(): RefreshTokenNuevo {
  const token = randomBytes(48).toString('base64url');   // 64 caracteres: letras, números, - y _
  return {
    token,
    hash: hashearToken(token),
    expiraEn: new Date(Date.now() + env.REFRESH_TOKEN_DAYS * 24 * 60 * 60 * 1000),
  };
}
export function crearAccessToken(usuario: { IDUsuario: number; NombreRol: string }): string {
  return jwt.sign({ rol: usuario.NombreRol }, env.JWT_SECRET, {
    subject: String(usuario.IDUsuario),
    algorithm: ALGORITMO,
    expiresIn: env.JWT_ACCESS_MINUTES * 60,
  });
}
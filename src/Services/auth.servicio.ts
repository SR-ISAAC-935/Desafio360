import bcrypt from 'bcryptjs';
import { env } from '../config/env';
import { ejecutarSP } from '../db/ejecutarSP';
import { P } from '../db/parametros';
import { AppError } from '../errors/AppError';
import type { InicioSesionDto, RegistroDto } from '../schemas/auth.schemas';
import { crearAccessToken, crearRefreshToken, hashearToken } from './tokens.servicio';

interface UsuarioRow {
  IDUsuario: number; Email: string; NombreCompleto: string; PasswordHash: string;
  Activo: boolean; IDRol: number; NombreRol: string;
}
export type UsuarioPublico = Omit<UsuarioRow, 'PasswordHash'>;
export interface UsuarioRegistrado { IDUsuario: number; Email: string; NombreCompleto: string; NombreRol: string; }
export interface SesionTokens { accessToken: string; refreshToken: string; }

const HASH_DE_RELLENO = bcrypt.hashSync('contrasena-que-nadie-usa', env.BCRYPT_ROUNDS);

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

/** Login: valida credenciales, guarda el HASH del refresh token y entrega ambos tokens. */
export async function iniciarSesion(datos: InicioSesionDto, ip?: string): Promise<{ usuario: UsuarioPublico } & SesionTokens> {
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

/** Renovar: el procedimiento revoca el refresh token usado y registra el nuevo (rotación). */
export async function renovarSesion(refreshToken: string, ip?: string): Promise<SesionTokens> {
  const nuevo = crearRefreshToken();

  const resultado = await ejecutarSP('SP_Auth_RotarRefreshToken', [
    P.char('TokenHashActual', 64, hashearToken(refreshToken)),
    P.char('TokenHashNuevo', 64, nuevo.hash),
    P.fechaHora('FechaExpiracionNueva', nuevo.expiraEn),
    P.varchar('DireccionIP', 45, ip),
  ]);

  const usuario = resultado.primera<{ IDUsuario: number; NombreRol: string }>();
  if (!usuario) throw new AppError(500, 'ERROR_INTERNO', 'No se pudo renovar la sesión.');

  return { accessToken: crearAccessToken(usuario), refreshToken: nuevo.token };
}

/** Logout: revoca el refresh token. Si ya estaba revocado o no existe, no pasa nada (es idempotente). */
export async function cerrarSesion(refreshToken: string): Promise<void> {
  await ejecutarSP('SP_Auth_RevocarRefreshToken', [P.char('TokenHash', 64, hashearToken(refreshToken))]);
}

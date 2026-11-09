import type { Request, Response } from 'express';
import { inicioSesionSchema, refreshTokenSchema, registroSchema } from '../schemas/auth.schemas';
import * as servicio from '../Services/auth.servicio';
import { usuarioDe } from '../utils/solicitud';
import { refreshCookieOptions } from '../config/cookies';

export async function registro(req: Request, res: Response): Promise<void> {
  const usuario = await servicio.registrarUsuario(registroSchema.parse(req.body));
  res.status(201).json({ usuario });
}

export async function login(req: Request, res: Response): Promise<void> {
  const sesion = await servicio.iniciarSesion(inicioSesionSchema.parse(req.body), req.ip);
  res.json(sesion);
}
export async function logins(req: Request, res: Response): Promise<void> {

  const sesion = await servicio.iniciarSesion(inicioSesionSchema.parse(req.body), req.ip);
  const {refreshToken,...datosSesion}= sesion
  res.cookie('refreshtoken', refreshToken, refreshCookieOptions);
  res.json(datosSesion);
}

export async function renovar(req: Request, res: Response): Promise<void> {
  const { refreshToken } = refreshTokenSchema.parse(req.body);
  res.json(await servicio.renovarSesion(refreshToken, req.ip));
}

export async function logout(req: Request, res: Response): Promise<void> {
  const { refreshToken } = refreshTokenSchema.parse(req.body);
  await servicio.cerrarSesion(refreshToken);
  res.status(204).send();
}

export async function yo(req: Request, res: Response): Promise<void> {
  res.json({ usuario: await servicio.obtenerPerfil(usuarioDe(req).id) });
}

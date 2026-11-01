import type { Request, Response } from 'express';
import { inicioSesionSchema, refreshTokenSchema, registroSchema } from '../schemas/auth.schemas';
import * as servicio from '../servicios/auth.servicio';

export async function registro(req: Request, res: Response): Promise<void> {
  const usuario = await servicio.registrarUsuario(registroSchema.parse(req.body));
  res.status(201).json({ usuario });
}

export async function login(req: Request, res: Response): Promise<void> {
  const sesion = await servicio.iniciarSesion(inicioSesionSchema.parse(req.body), req.ip);
  res.json(sesion);
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

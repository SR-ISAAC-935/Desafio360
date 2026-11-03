import type { Request, Response } from 'express';
import {
  agregarItemSchema,
  aplicarCuponSchema,
  cambiarCantidadSchema,
  CABECERA_TOKEN_CARRITO,
  idVarianteParamSchema,
  tokenInvitadoSchema,
} from '../schemas/carrito.schemas';
import { AppError } from '../errors/AppError';
import * as servicio from '../Services/carrito.servicio';
import { duenoDelCarrito, duenoExistenteDelCarrito, usuarioDe } from '../utils/solicitud';

/** Ver el carrito. Un invitado sin carrito recibe uno nuevo y su tokenInvitado, que debe guardar. */
export async function ver(req: Request, res: Response): Promise<void> {
  res.json(await servicio.verCarrito(duenoDelCarrito(req)));
}

export async function agregar(req: Request, res: Response): Promise<void> {
  const datos = agregarItemSchema.parse(req.body);
  res.json(await servicio.agregarProducto(duenoDelCarrito(req), datos));
}

export async function cambiarCantidad(req: Request, res: Response): Promise<void> {
  const { idVariante } = idVarianteParamSchema.parse(req.params);
  const datos = cambiarCantidadSchema.parse(req.body);
  res.json(await servicio.cambiarCantidad(duenoExistenteDelCarrito(req), idVariante, datos));
}

export async function quitar(req: Request, res: Response): Promise<void> {
  const { idVariante } = idVarianteParamSchema.parse(req.params);
  res.json(await servicio.quitarProducto(duenoExistenteDelCarrito(req), idVariante));
}

export async function aplicarCupon(req: Request, res: Response): Promise<void> {
  const datos = aplicarCuponSchema.parse(req.body);
  res.json(await servicio.aplicarCupon(usuarioDe(req).id, datos));
}

export async function quitarCupon(req: Request, res: Response): Promise<void> {
  res.json(await servicio.quitarCupon(usuarioDe(req).id));
}

/** Después de iniciar sesión: el carrito del invitado (cabecera X-Carrito-Token) pasa al usuario o se suma al suyo. */
export async function fusionar(req: Request, res: Response): Promise<void> {
  const crudo = req.header(CABECERA_TOKEN_CARRITO);
  const token = tokenInvitadoSchema.safeParse(crudo?.trim());
  if (!token.success) {
    throw new AppError(400, 'TOKEN_CARRITO_INVALIDO', 'Envíe la cabecera X-Carrito-Token con el token de su carrito de invitado.');
  }
  res.json(await servicio.fusionarCarritos(usuarioDe(req).id, token.data));
}

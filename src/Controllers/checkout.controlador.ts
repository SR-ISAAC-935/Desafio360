import type { Request, Response } from 'express';
import { pagarSchema } from '../schemas/checkout.schemas';
import * as servicio from '../Services/checkout.servicio';
import { usuarioDe } from '../utils/solicitud';

/** Paso 1: reservar la existencia por 15 minutos. */
export async function reservar(req: Request, res: Response): Promise<void> {
  res.json(await servicio.reservar(usuarioDe(req).id));
}

/**
 * Paso 2: pagar y crear el pedido. 201 si se creó; 200 si la llave de idempotencia ya existía
 * (reintento o doble clic) y se devuelve el pedido anterior sin cobrar otra vez.
 */
export async function pagar(req: Request, res: Response): Promise<void> {
  const datos = pagarSchema.parse(req.body);
  const resultado = await servicio.pagar(usuarioDe(req).id, datos);
  res.status(resultado.repetido ? 200 : 201).json(resultado);
}

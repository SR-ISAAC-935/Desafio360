import type { Request, Response } from 'express';
import { idParamSchema } from '../schemas/comunes.schemas';
import { actualizarCuponSchema, crearCuponSchema, listarCuponesQuerySchema } from '../schemas/cupones.schemas';
import * as servicio from '../Services/cupones.servicio';
import { armarPagina } from '../utils/paginacion';
import { usuarioDe } from '../utils/solicitud';

export async function listar(req: Request, res: Response): Promise<void> {
  const q = listarCuponesQuerySchema.parse(req.query);
  const filas = await servicio.listarCupones(usuarioDe(req).id, q);
  res.json(armarPagina(filas, q.pagina, q.tamanoPagina));
}

export async function crear(req: Request, res: Response): Promise<void> {
  const datos = crearCuponSchema.parse(req.body);
  res.status(201).json(await servicio.crearCupon(usuarioDe(req).id, datos));
}

export async function actualizar(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  const datos = actualizarCuponSchema.parse(req.body);
  await servicio.actualizarCupon(usuarioDe(req).id, id, datos);
  res.status(204).send();
}

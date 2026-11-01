import type { Request, Response } from 'express';
import { idParamSchema } from '../schemas/comunes.schemas';
import { crearDireccionSchema } from '../schemas/direcciones.schemas';
import * as servicio from '../servicios/direcciones.servicio';
import { usuarioDe } from '../utils/solicitud';

export async function listar(req: Request, res: Response): Promise<void> {
  res.json(await servicio.listarDirecciones(usuarioDe(req).id));
}

export async function crear(req: Request, res: Response): Promise<void> {
  const datos = crearDireccionSchema.parse(req.body);
  res.status(201).json(await servicio.crearDireccion(usuarioDe(req).id, datos));
}

export async function desactivar(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  await servicio.desactivarDireccion(usuarioDe(req).id, id);
  res.status(204).send();
}

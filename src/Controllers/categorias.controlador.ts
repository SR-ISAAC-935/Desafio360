import type { Request, Response } from 'express';
import { actualizarCategoriaSchema, crearCategoriaSchema } from '../schemas/categorias.schemas';
import { idParamSchema } from '../schemas/comunes.schemas';
import { listarCategorias } from '../Services/catalogo.servicio';
import * as servicio from '../Services/categorias.servicio';
import { usuarioDe } from '../utils/solicitud';

/** Para el backoffice: incluye las categorías inactivas. */
export async function listar(_req: Request, res: Response): Promise<void> {
  res.json(await listarCategorias(false));
}

export async function crear(req: Request, res: Response): Promise<void> {
  const datos = crearCategoriaSchema.parse(req.body);
  res.status(201).json(await servicio.crearCategoria(usuarioDe(req).id, datos));
}

export async function actualizar(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  const datos = actualizarCategoriaSchema.parse(req.body);
  await servicio.actualizarCategoria(usuarioDe(req).id, id, datos);
  res.status(204).send();
}

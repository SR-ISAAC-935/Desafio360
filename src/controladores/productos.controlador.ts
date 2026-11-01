import type { Request, Response } from 'express';
import { idParamSchema } from '../schemas/comunes.schemas';
import {
  actualizarProductoSchema,
  actualizarVarianteSchema,
  cambiarPrecioSchema,
  crearProductoSchema,
  varianteNuevaSchema,
} from '../schemas/productos.schemas';
import { obtenerProducto } from '../servicios/catalogo.servicio';
import * as servicio from '../servicios/productos.servicio';
import { usuarioDe } from '../utils/solicitud';

/** Para el backoffice: devuelve el producto aunque esté inactivo. */
export async function detalle(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  res.json(await obtenerProducto(id, true));
}

export async function crear(req: Request, res: Response): Promise<void> {
  const datos = crearProductoSchema.parse(req.body);
  res.status(201).json(await servicio.crearProducto(usuarioDe(req).id, datos));
}

export async function actualizar(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  const datos = actualizarProductoSchema.parse(req.body);
  await servicio.actualizarProducto(usuarioDe(req).id, id, datos);
  res.status(204).send();
}

export async function crearVariante(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  const datos = varianteNuevaSchema.parse(req.body);
  res.status(201).json(await servicio.crearVariante(usuarioDe(req).id, id, datos));
}

export async function actualizarVariante(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  const datos = actualizarVarianteSchema.parse(req.body);
  await servicio.actualizarVariante(usuarioDe(req).id, id, datos);
  res.status(204).send();
}

export async function cambiarPrecio(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  const datos = cambiarPrecioSchema.parse(req.body);
  await servicio.cambiarPrecio(usuarioDe(req).id, id, datos);
  res.status(204).send();
}

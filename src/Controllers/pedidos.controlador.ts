import type { Request, Response } from 'express';
import { idParamSchema } from '../schemas/comunes.schemas';
import {
  avanzarEstadoSchema,
  cancelarPedidoSchema,
  devolucionSchema,
  listarPedidosQuerySchema,
  misPedidosQuerySchema,
} from '../schemas/pedidos.schemas';
import * as servicio from '../Services/pedidos.servicio';
import { armarPagina } from '../utils/paginacion';
import { usuarioDe } from '../utils/solicitud';

export async function estados(_req: Request, res: Response): Promise<void> {
  res.json(await servicio.listarEstados());
}

export async function misPedidos(req: Request, res: Response): Promise<void> {
  const q = misPedidosQuerySchema.parse(req.query);
  const filas = await servicio.listarMios(usuarioDe(req).id, q);
  res.json(armarPagina(filas, q.pagina, q.tamanoPagina));
}

export async function listar(req: Request, res: Response): Promise<void> {
  const q = listarPedidosQuerySchema.parse(req.query);
  const filas = await servicio.listarTodos(usuarioDe(req).id, q);
  res.json(armarPagina(filas, q.pagina, q.tamanoPagina));
}

export async function detalle(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  res.json(await servicio.obtenerDetalle(id, usuarioDe(req).id));
}

export async function cancelar(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  const datos = cancelarPedidoSchema.parse(req.body);
  res.json(await servicio.cancelar(id, usuarioDe(req).id, datos));
}

export async function avanzar(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  const datos = avanzarEstadoSchema.parse(req.body);
  res.json(await servicio.avanzarEstado(id, usuarioDe(req).id, datos));
}

export async function devolver(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  const datos = devolucionSchema.parse(req.body);
  res.status(201).json(await servicio.registrarDevolucion(id, usuarioDe(req).id, datos));
}

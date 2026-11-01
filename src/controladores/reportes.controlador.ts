import type { Request, Response } from 'express';
import {
  abandonadosQuerySchema,
  rangoQuerySchema,
  resumenQuerySchema,
  topProductosQuerySchema,
  ventasQuerySchema,
} from '../schemas/reportes.schemas';
import * as servicio from '../Services/reportes.servicio';
import { armarPagina } from '../utils/paginacion';
import { usuarioDe } from '../utils/solicitud';

export async function ventas(req: Request, res: Response): Promise<void> {
  res.json(await servicio.ventasPorPeriodo(usuarioDe(req).id, ventasQuerySchema.parse(req.query)));
}

export async function porCategoria(req: Request, res: Response): Promise<void> {
  res.json(await servicio.ventasPorCategoria(usuarioDe(req).id, rangoQuerySchema.parse(req.query)));
}

export async function topProductos(req: Request, res: Response): Promise<void> {
  res.json(await servicio.topProductos(usuarioDe(req).id, topProductosQuerySchema.parse(req.query)));
}

export async function resumen(req: Request, res: Response): Promise<void> {
  res.json(await servicio.resumen(usuarioDe(req).id, resumenQuerySchema.parse(req.query)));
}

export async function abandonados(req: Request, res: Response): Promise<void> {
  const q = abandonadosQuerySchema.parse(req.query);
  const filas = await servicio.carritosAbandonados(usuarioDe(req).id, q);
  res.json(armarPagina(filas, q.pagina, q.tamanoPagina));
}

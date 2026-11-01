import type { Request, Response } from 'express';
import { idParamSchema } from '../schemas/comunes.schemas';
import { ajusteSchema, entradasSchema, existenciasQuerySchema, kardexQuerySchema } from '../schemas/inventario.schemas';
import * as servicio from '../servicios/inventario.servicio';
import { armarPagina } from '../utils/paginacion';
import { usuarioDe } from '../utils/solicitud';

export async function existencias(req: Request, res: Response): Promise<void> {
  const q = existenciasQuerySchema.parse(req.query);
  const filas = await servicio.listarExistencias(usuarioDe(req).id, q);
  res.json(armarPagina(filas, q.pagina, q.tamanoPagina));
}

export async function kardex(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  const q = kardexQuerySchema.parse(req.query);
  const filas = await servicio.consultarKardex(usuarioDe(req).id, id, q);
  res.json(armarPagina(filas, q.pagina, q.tamanoPagina));
}

export async function ajustar(req: Request, res: Response): Promise<void> {
  const datos = ajusteSchema.parse(req.body);
  res.status(201).json(await servicio.ajustarExistencia(usuarioDe(req).id, datos));
}

export async function registrarEntradas(req: Request, res: Response): Promise<void> {
  const datos = entradasSchema.parse(req.body);
  res.status(201).json(await servicio.registrarEntradas(usuarioDe(req).id, datos));
}

export async function verificar(_req: Request, res: Response): Promise<void> {
  const diferencias = await servicio.verificarKardex();
  res.json({ coincide: diferencias.length === 0, diferencias });
}

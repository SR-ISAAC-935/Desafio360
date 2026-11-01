import type { Request, Response } from 'express';
import { buscarCatalogoQuerySchema } from '../schemas/catalogo.schemas';
import { idParamSchema } from '../schemas/comunes.schemas';
import * as servicio from '../servicios/catalogo.servicio';
import { armarPagina } from '../utils/paginacion';

export async function categorias(_req: Request, res: Response): Promise<void> {
  res.json(await servicio.listarCategorias(true));
}

export async function buscar(req: Request, res: Response): Promise<void> {
  const q = buscarCatalogoQuerySchema.parse(req.query);
  res.json(armarPagina(await servicio.buscarProductos(q), q.pagina, q.tamanoPagina));
}

export async function detalle(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  res.json(await servicio.obtenerProducto(id, false));
}

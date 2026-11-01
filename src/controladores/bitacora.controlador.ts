import type { Request, Response } from 'express';
import { bitacoraQuerySchema } from '../schemas/bitacora.schemas';
import * as servicio from '../servicios/bitacora.servicio';
import { armarPagina } from '../utils/paginacion';
import { usuarioDe } from '../utils/solicitud';

export async function listar(req: Request, res: Response): Promise<void> {
  const q = bitacoraQuerySchema.parse(req.query);
  const filas = await servicio.listarBitacora(usuarioDe(req).id, q);
  res.json(armarPagina(filas, q.pagina, q.tamanoPagina));
}

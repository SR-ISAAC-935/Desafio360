import type { Request, Response } from 'express';
import { idParamSchema } from '../schemas/comunes.schemas';
import { cambiarEstadoUsuarioSchema, crearUsuarioSchema, listarUsuariosQuerySchema } from '../schemas/usuarios.schemas';
import * as servicio from '../servicios/usuarios.servicio';
import { armarPagina } from '../utils/paginacion';
import { usuarioDe } from '../utils/solicitud';

export async function listar(req: Request, res: Response): Promise<void> {
  const q = listarUsuariosQuerySchema.parse(req.query);
  const filas = await servicio.listarUsuarios(usuarioDe(req).id, q);
  res.json(armarPagina(filas, q.pagina, q.tamanoPagina));
}

export async function crear(req: Request, res: Response): Promise<void> {
  const datos = crearUsuarioSchema.parse(req.body);
  res.status(201).json(await servicio.crearUsuario(usuarioDe(req).id, datos));
}

export async function cambiarEstado(req: Request, res: Response): Promise<void> {
  const { id } = idParamSchema.parse(req.params);
  const datos = cambiarEstadoUsuarioSchema.parse(req.body);
  await servicio.cambiarEstadoUsuario(usuarioDe(req).id, id, datos);
  res.status(204).send();
}

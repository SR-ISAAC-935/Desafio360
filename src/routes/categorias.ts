import { Router } from 'express';
import { actualizar, crear, listar } from '../Controllers/categorias.controlador';
import { autenticar, exigirRol } from '../middlewares/autenticacion';

export const rutasCategorias = Router();

rutasCategorias.use(autenticar, exigirRol('Administrador'));

rutasCategorias.get('/', listar);
rutasCategorias.post('/', crear);
rutasCategorias.put('/:id', actualizar);

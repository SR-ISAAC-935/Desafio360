import { Router } from 'express';
import { actualizar, crear, listar } from '../Controllers/cupones.controlador';
import { autenticar, exigirRol } from '../middlewares/autenticacion';

export const rutasCupones = Router();

rutasCupones.use(autenticar, exigirRol('Administrador'));

rutasCupones.get('/', listar);
rutasCupones.post('/', crear);
rutasCupones.put('/:id', actualizar);

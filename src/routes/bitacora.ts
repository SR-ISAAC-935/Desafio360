import { Router } from 'express';
import { listar } from '../controladores/bitacora.controlador';
import { autenticar, exigirRol } from '../middlewares/autenticacion';

export const rutasBitacora = Router();

rutasBitacora.use(autenticar, exigirRol('Administrador'));

// Solo lectura: la bitácora no se modifica ni se elimina
rutasBitacora.get('/', listar);

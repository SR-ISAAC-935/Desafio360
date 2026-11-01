import { Router } from 'express';
import { crear, desactivar, listar } from '../controladores/direcciones.controlador';
import { autenticar, exigirRol } from '../middlewares/autenticacion';

export const rutasDirecciones = Router();

// Las direcciones de entrega son del cliente que compra
rutasDirecciones.use(autenticar, exigirRol('Cliente'));

rutasDirecciones.get('/', listar);
rutasDirecciones.post('/', crear);
rutasDirecciones.delete('/:id', desactivar);

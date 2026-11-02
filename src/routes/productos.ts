import { Router } from 'express';
import {
  actualizar,
  actualizarVariante,
  cambiarPrecio,
  crear,
  crearVariante,
  detalle,
} from '../controladores/productos.controlador';
import { autenticar, exigirRol } from '../middlewares/autenticacion';

// /api/productos
export const rutasProductos = Router();
rutasProductos.use(autenticar, exigirRol('Administrador'));

rutasProductos.get('/:id', detalle);
rutasProductos.post('/', crear);
rutasProductos.put('/:id', actualizar);
rutasProductos.post('/:id/variantes', crearVariante);

// /api/variantes
export const rutasVariantes = Router();
rutasVariantes.use(autenticar, exigirRol('Administrador'));

rutasVariantes.put('/:id', actualizarVariante);
rutasVariantes.patch('/:id/precio', cambiarPrecio);

import { Router } from 'express';
import { avanzar, cancelar, detalle, devolver, estados, listar, misPedidos } from '../Controllers/pedidos.controlador';
import { autenticar, exigirRol } from '../middlewares/autenticacion';

export const rutasPedidos = Router();

rutasPedidos.use(autenticar);

// Rutas fijas primero: si no, "/mios" y "/estados" se confundirían con "/:id"
rutasPedidos.get('/estados', estados);
rutasPedidos.get('/mios', exigirRol('Cliente'), misPedidos);

// Personal: Operador y Administrador
rutasPedidos.get('/', exigirRol('Operador', 'Administrador'), listar);
rutasPedidos.patch('/:id/estado', exigirRol('Operador', 'Administrador'), avanzar);
rutasPedidos.post('/:id/devoluciones', exigirRol('Operador', 'Administrador'), devolver);

// Dueño o personal: lo decide el procedimiento (otro cliente recibe 403)
rutasPedidos.get('/:id', detalle);
rutasPedidos.post('/:id/cancelar', cancelar);

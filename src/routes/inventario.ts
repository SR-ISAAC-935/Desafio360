import { Router } from 'express';
import { ajustar, existencias, kardex, liberarReservas, registrarEntradas, verificar } from '../Controllers/inventario.controlador';
import { autenticar, exigirRol } from '../middlewares/autenticacion';

export const rutasInventario = Router();

rutasInventario.use(autenticar);

// Operador y Administrador
rutasInventario.get('/existencias', exigirRol('Operador', 'Administrador'), existencias);
rutasInventario.get('/variantes/:id/kardex', exigirRol('Operador', 'Administrador'), kardex);
rutasInventario.post('/ajustes', exigirRol('Operador', 'Administrador'), ajustar);
rutasInventario.post('/entradas', exigirRol('Operador', 'Administrador'), registrarEntradas);

// Solo Administrador: comprobación de integridad (existencia = suma del kardex)
rutasInventario.get('/verificar', exigirRol('Administrador'), verificar);
rutasInventario.post('/liberar-reservas', exigirRol('Administrador'), liberarReservas);

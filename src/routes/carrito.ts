import { Router } from 'express';
import { agregar, aplicarCupon, cambiarCantidad, fusionar, quitar, quitarCupon, ver } from '../Controllers/carrito.controlador';
import { autenticarOpcional, exigirClienteOInvitado, exigirRol } from '../middlewares/autenticacion';

export const rutasCarrito = Router();

// Sirve a invitados (cabecera X-Carrito-Token) y a clientes con sesión. Operador y Administrador no compran.
rutasCarrito.use(autenticarOpcional, exigirClienteOInvitado);

rutasCarrito.get('/', ver);
rutasCarrito.post('/items', agregar);
rutasCarrito.patch('/items/:idVariante', cambiarCantidad);
rutasCarrito.delete('/items/:idVariante', quitar);

// Solo con sesión: el límite de usos de un cupón es por cliente (exigirRol responde 401 si no hay sesión)
rutasCarrito.post('/cupon', exigirRol('Cliente'), aplicarCupon);
rutasCarrito.delete('/cupon', exigirRol('Cliente'), quitarCupon);
rutasCarrito.post('/fusionar', exigirRol('Cliente'), fusionar);

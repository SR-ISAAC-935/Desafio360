import { Router } from 'express';
import { pagar, reservar } from '../Controllers/checkout.controlador';
import { autenticar, exigirRol } from '../middlewares/autenticacion';

export const rutasCheckout = Router();

// Solo el Cliente compra
rutasCheckout.use(autenticar, exigirRol('Cliente'));

rutasCheckout.post('/reservar', reservar);
rutasCheckout.post('/pagar', pagar);

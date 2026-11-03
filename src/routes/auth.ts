import { Router } from 'express';
import { login, logout, registro, renovar, yo } from '../Controllers/auth.controlador';
import { autenticar } from '../middlewares/autenticacion';

export const rutasAuth = Router();

rutasAuth.post('/registro', registro);
rutasAuth.post('/login', login);
rutasAuth.post('/refresh', renovar);
rutasAuth.post('/logout', logout);

rutasAuth.get('/yo', autenticar, yo); // perfil del usuario con sesión

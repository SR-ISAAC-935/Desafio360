import { Router } from 'express';
import { login, logout, registro, renovar } from '../controladores/auth.controlador';

export const rutasAuth = Router();

rutasAuth.post('/registro', registro);
rutasAuth.post('/login', login);
rutasAuth.post('/refresh', renovar);
rutasAuth.post('/logout', logout);

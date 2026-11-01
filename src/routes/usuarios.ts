import { Router } from 'express';
import { cambiarEstado, crear, listar } from '../controladores/usuarios.controlador';
import { autenticar, exigirRol } from '../middlewares/autenticacion';

export const rutasUsuarios = Router();

// Administración de cuentas: solo Administrador
rutasUsuarios.use(autenticar, exigirRol('Administrador'));

rutasUsuarios.get('/', listar);
rutasUsuarios.post('/', crear);
rutasUsuarios.patch('/:id/estado', cambiarEstado);

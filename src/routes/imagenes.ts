import { Router } from 'express';
import { firma } from '../Controllers/imagenes.controlador';
import { autenticar, exigirRol } from '../middlewares/autenticacion';

export const rutasImagenes = Router();

// Solo quien administra el catálogo sube imágenes de productos
rutasImagenes.use(autenticar, exigirRol('Administrador'));

rutasImagenes.post('/firma', firma);

import { Router } from 'express';
import { buscar, categorias, detalle } from '../controladores/catalogo.controlador';

export const rutasCatalogo = Router();

// Tienda pública: no requiere sesión
rutasCatalogo.get('/categorias', categorias);
rutasCatalogo.get('/productos', buscar);
rutasCatalogo.get('/productos/:id', detalle);

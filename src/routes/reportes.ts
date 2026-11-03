import { Router } from 'express';
import { abandonados, porCategoria, resumen, topProductos, ventas } from '../Controllers/reportes.controlador';
import { autenticar, exigirRol } from '../middlewares/autenticacion';

export const rutasReportes = Router();

rutasReportes.use(autenticar, exigirRol('Administrador'));

rutasReportes.get('/ventas', ventas);
rutasReportes.get('/categorias', porCategoria);
rutasReportes.get('/top-productos', topProductos);
rutasReportes.get('/resumen', resumen);
rutasReportes.get('/carritos-abandonados', abandonados);

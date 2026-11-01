import { Router } from 'express';
import { limitadorAutenticacion } from '../middlewares/limitadores';
import { P } from '../db/parametros';
import { ejecutarSP } from '../db/ejecutarSP';
import { rutasAuth } from './auth';
import { rutasBitacora } from './bitacora';
import { rutasCatalogo } from './catalogo';
import { rutasCategorias } from './categorias';
import { rutasCupones } from './cupones';
import { rutasDirecciones } from './direcciones';
import { rutasInventario } from './inventario';
import { rutasProductos, rutasVariantes } from './productos';
import { rutasReportes } from './reportes';
import { rutasUsuarios } from './usuarios';

export const rutas = Router();

// Comprobación de salud: confirma que la API y la base de datos responden (solo usa un SP).
rutas.get('/salud', async (_req, res) => {
  await ejecutarSP('SP_Categorias_Listar', [P.bit('SoloActivas', true)]);
  res.json({ estado: 'ok', baseDeDatos: 'ok' });
});

// Sesión
rutas.use('/auth', limitadorAutenticacion, rutasAuth);

// Tienda pública
rutas.use('/catalogo', rutasCatalogo);

// Cliente
rutas.use('/direcciones', rutasDirecciones);
// TODO (pendiente): carrito, checkout y pedidos del cliente

// Operador y Administrador
rutas.use('/inventario', rutasInventario);
// TODO (pendiente): pedidos del personal (listar, avanzar estado, devoluciones)

// Administrador
rutas.use('/usuarios', rutasUsuarios);
rutas.use('/categorias', rutasCategorias);
rutas.use('/productos', rutasProductos);
rutas.use('/variantes', rutasVariantes);
rutas.use('/cupones', rutasCupones);
rutas.use('/reportes', rutasReportes);
rutas.use('/bitacora', rutasBitacora);

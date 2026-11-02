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
import { exigirRol } from '../middlewares/autenticacion';

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
rutas.use('/inventario',exigirRol('Administrador'), rutasInventario);
// TODO (pendiente): pedidos del personal (listar, avanzar estado, devoluciones)

// Administrador
rutas.use('/usuarios' ,exigirRol('Administrador'), rutasUsuarios);
rutas.use('/categorias' ,exigirRol('Administrador'), rutasCategorias);
rutas.use('/productos' ,exigirRol('Administrador'), rutasProductos);
rutas.use('/variantes' ,exigirRol('Administrador'), rutasVariantes);
rutas.use('/cupones' ,exigirRol('Administrador'), rutasCupones);
rutas.use('/reportes' ,exigirRol('Administrador'), rutasReportes);
rutas.use('/bitacora' ,exigirRol('Administrador'), rutasBitacora);

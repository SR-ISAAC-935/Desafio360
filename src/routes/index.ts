import { Router } from 'express';
import { limitadorAutenticacion } from '../middlewares/limitadores';
import { P } from '../db/parametros';
import { ejecutarSP } from '../db/ejecutarSP';
import { rutasAuth } from './auth';
import { rutasBitacora } from './bitacora';
import { rutasCarrito } from './carrito';
import { rutasCatalogo } from './catalogo';
import { rutasCategorias } from './categorias';
import { rutasCheckout } from './checkout';
import { rutasCupones } from './cupones';
import { rutasDirecciones } from './direcciones';
import { rutasImagenes } from './imagenes';
import { rutasInventario } from './inventario';
import { rutasPedidos } from './pedidos';
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

// Carrito: invitados (cabecera X-Carrito-Token) y clientes con sesión
rutas.use('/carrito', rutasCarrito);

// Cliente
rutas.use('/direcciones', rutasDirecciones);
rutas.use('/checkout', rutasCheckout);

// Pedidos: cliente (los suyos) y personal (todos); cada ruta define quién puede usarla
rutas.use('/pedidos', rutasPedidos);

// Operador y Administrador
rutas.use('/inventario', rutasInventario);

// Administrador
rutas.use('/usuarios', rutasUsuarios);
rutas.use('/categorias', rutasCategorias);
rutas.use('/productos', rutasProductos);
rutas.use('/imagenes', rutasImagenes);
rutas.use('/variantes', rutasVariantes);
rutas.use('/cupones', rutasCupones);
rutas.use('/reportes', rutasReportes);
rutas.use('/bitacora', rutasBitacora);

import { z } from 'zod';
import { inicioSesionSchema, refreshTokenSchema, registroSchema } from '../schemas/auth.schemas';
import { bitacoraQuerySchema } from '../schemas/bitacora.schemas';
import { agregarItemSchema, aplicarCuponSchema, cambiarCantidadSchema } from '../schemas/carrito.schemas';
import { buscarCatalogoQuerySchema } from '../schemas/catalogo.schemas';
import { actualizarCategoriaSchema, crearCategoriaSchema } from '../schemas/categorias.schemas';
import { pagarSchema } from '../schemas/checkout.schemas';
import { actualizarCuponSchema, crearCuponSchema, listarCuponesQuerySchema } from '../schemas/cupones.schemas';
import { crearDireccionSchema } from '../schemas/direcciones.schemas';
import {
  ajusteSchema,
  entradasSchema,
  existenciasQuerySchema,
  kardexQuerySchema,
} from '../schemas/inventario.schemas';
import {
  avanzarEstadoSchema,
  cancelarPedidoSchema,
  devolucionSchema,
  listarPedidosQuerySchema,
  misPedidosQuerySchema,
} from '../schemas/pedidos.schemas';
import {
  actualizarProductoSchema,
  actualizarVarianteSchema,
  cambiarPrecioSchema,
  crearProductoSchema,
  varianteNuevaSchema,
} from '../schemas/productos.schemas';
import {
  abandonadosQuerySchema,
  rangoQuerySchema,
  resumenQuerySchema,
  topProductosQuerySchema,
  ventasQuerySchema,
} from '../schemas/reportes.schemas';
import { cambiarEstadoUsuarioSchema, crearUsuarioSchema, listarUsuariosQuerySchema } from '../schemas/usuarios.schemas';

/**
 * Especificación OpenAPI 3.0 de la API.
 *
 * Los cuerpos y los parámetros de consulta NO se escriben a mano: se generan a partir de los mismos esquemas Zod
 * que validan las solicitudes en tiempo de ejecución. Así la documentación no puede quedar desactualizada
 * respecto a lo que la API realmente acepta.
 */

type Json = Record<string, unknown>;

const MAX_SEGURO = Number.MAX_SAFE_INTEGER;

/** Convierte un esquema Zod (en su forma de ENTRADA) a JSON Schema de OpenAPI 3.0 y quita el ruido numérico. */
function aJsonSchema(esquema: z.ZodType): Json {
  const bruto = z.toJSONSchema(esquema, { io: 'input', unrepresentable: 'any', target: 'openapi-3.0' } as never) as Json;
  const limpiar = (nodo: unknown): unknown => {
    if (Array.isArray(nodo)) return nodo.map(limpiar);
    if (nodo === null || typeof nodo !== 'object') return nodo;
    const salida: Json = {};
    for (const [clave, valor] of Object.entries(nodo as Json)) {
      if (clave === '$schema') continue;
      if (clave === 'maximum' && valor === MAX_SEGURO) continue;
      salida[clave] = limpiar(valor);
    }
    return salida;
  };
  return limpiar(bruto) as Json;
}

/** Cada propiedad del esquema de consulta se vuelve un parámetro `in: query`. */
function parametrosDeConsulta(esquema: z.ZodType): Json[] {
  const js = aJsonSchema(esquema);
  const propiedades = (js['properties'] ?? {}) as Record<string, Json>;
  const requeridos = new Set((js['required'] ?? []) as string[]);
  return Object.entries(propiedades).map(([nombre, schema]) => ({
    name: nombre,
    in: 'query',
    required: requeridos.has(nombre),
    schema,
  }));
}

type Acceso = 'publico' | 'sesion' | 'carrito' | 'carritoOpcional';

interface Endpoint {
  metodo: 'get' | 'post' | 'put' | 'patch' | 'delete';
  ruta: string;
  tag: string;
  resumen: string;
  descripcion?: string;
  acceso: Acceso;
  /** Roles que pueden usarlo (solo documentación; la verificación real está en el middleware y en el procedimiento). */
  roles?: string[];
  cuerpo?: z.ZodType;
  ejemplo?: unknown;
  consulta?: z.ZodType;
  /** Código de éxito y su descripción. */
  ok: [number, string, string?];
  /** Errores adicionales que el endpoint puede devolver. */
  errores?: number[];
}

const E: Endpoint[] = [];
const ep = (e: Endpoint): void => {
  E.push(e);
};

// ───────────────────────────── Salud
ep({
  metodo: 'get', ruta: '/salud', tag: 'Salud', resumen: 'Comprobar que la API y la base de datos responden',
  acceso: 'publico', ok: [200, 'Todo funciona', 'Salud'], errores: [503],
});

// ───────────────────────────── Autenticación
ep({
  metodo: 'post', ruta: '/auth/registro', tag: 'Autenticación', resumen: 'Registrar un cliente',
  descripcion: 'Crea una cuenta con rol Cliente. La contraseña se guarda con bcrypt (máximo 72 bytes).',
  acceso: 'publico', cuerpo: registroSchema,
  ejemplo: { email: 'ana@correo.com', nombreCompleto: 'Ana López', password: 'Contraseña123!' },
  ok: [201, 'Usuario creado (sin hash de contraseña)', 'UsuarioRegistrado'], errores: [409, 429],
});
ep({
  metodo: 'post', ruta: '/auth/login', tag: 'Autenticación', resumen: 'Iniciar sesión',
  descripcion:
    'Devuelve un access token JWT (15 min) y un refresh token opaco (7 días). Ante cualquier fallo responde el mismo 401 genérico, ' +
    'exista o no el correo, para no permitir enumerar cuentas.',
  acceso: 'publico', cuerpo: inicioSesionSchema, ejemplo: { email: 'cliente@shopcart.test', password: 'Prueba123!' },
  ok: [200, 'Sesión iniciada', 'Sesion'], errores: [401, 429],
});
ep({
  metodo: 'post', ruta: '/auth/refresh', tag: 'Autenticación', resumen: 'Renovar la sesión (rotación de refresh token)',
  descripcion:
    'Entrega un access token y un refresh token NUEVOS e invalida el anterior. Si se presenta un refresh token ya usado se asume robo: ' +
    'se revocan todas las sesiones del usuario y se responde 401 (código SQL 50112).',
  acceso: 'publico', cuerpo: refreshTokenSchema, ok: [200, 'Tokens renovados', 'Tokens'], errores: [401, 403, 429],
});
ep({
  metodo: 'post', ruta: '/auth/logout', tag: 'Autenticación', resumen: 'Cerrar sesión',
  descripcion: 'Revoca el refresh token. Es idempotente: repetirlo no produce error.',
  acceso: 'publico', cuerpo: refreshTokenSchema, ok: [204, 'Sesión cerrada'], errores: [429],
});
ep({
  metodo: 'get', ruta: '/auth/yo', tag: 'Autenticación', resumen: 'Perfil del usuario con sesión',
  acceso: 'sesion', ok: [200, 'Perfil', 'PerfilRespuesta'],
});

// ───────────────────────────── Catálogo público
ep({
  metodo: 'get', ruta: '/catalogo/categorias', tag: 'Catálogo público', resumen: 'Categorías activas',
  acceso: 'publico', ok: [200, 'Lista de categorías'],
});
ep({
  metodo: 'get', ruta: '/catalogo/productos', tag: 'Catálogo público',
  resumen: 'Buscar productos',
  descripcion: 'Búsqueda con texto, categoría, rango de precio, disponibilidad, orden y paginación en el servidor.',
  acceso: 'publico', consulta: buscarCatalogoQuerySchema, ok: [200, 'Página de productos', 'Pagina'],
});
ep({
  metodo: 'get', ruta: '/catalogo/productos/{id}', tag: 'Catálogo público', resumen: 'Detalle de un producto con sus variantes',
  descripcion: 'Incluye la disponibilidad de cada variante (existencia física menos reservas vigentes).',
  acceso: 'publico', ok: [200, 'Producto y variantes'], errores: [404],
});

// ───────────────────────────── Carrito
const DUENO =
  'El carrito pertenece a quien hace la petición: el cliente nunca envía un IDCarrito. Un cliente se identifica con su access token; ' +
  'un invitado, con la cabecera `x-carrito-token` (que recibe en `tokenInvitado` al ver su carrito por primera vez). ' +
  'Un `Authorization` inválido responde 401 y nunca se degrada a invitado.';
ep({
  metodo: 'get', ruta: '/carrito', tag: 'Carrito', resumen: 'Ver el carrito (lo crea si no existe)',
  descripcion: DUENO, acceso: 'carritoOpcional', roles: ['Cliente', 'Invitado'], ok: [200, 'Carrito con líneas y totales', 'Carrito'], errores: [400],
});
ep({
  metodo: 'post', ruta: '/carrito/items', tag: 'Carrito', resumen: 'Agregar un producto',
  descripcion: 'Si la variante ya está en el carrito, la cantidad se SUMA a la línea existente. No se puede exceder la existencia disponible.',
  acceso: 'carritoOpcional', roles: ['Cliente', 'Invitado'], cuerpo: agregarItemSchema, ejemplo: { idVariante: 15, cantidad: 2 },
  ok: [200, 'Carrito actualizado', 'Carrito'], errores: [404, 409],
});
ep({
  metodo: 'patch', ruta: '/carrito/items/{idVariante}', tag: 'Carrito', resumen: 'Fijar la cantidad exacta de una línea',
  acceso: 'carritoOpcional', roles: ['Cliente', 'Invitado'], cuerpo: cambiarCantidadSchema, ejemplo: { cantidad: 3 },
  ok: [200, 'Carrito actualizado', 'Carrito'], errores: [404, 409],
});
ep({
  metodo: 'delete', ruta: '/carrito/items/{idVariante}', tag: 'Carrito', resumen: 'Quitar una línea del carrito',
  acceso: 'carritoOpcional', roles: ['Cliente', 'Invitado'], ok: [200, 'Carrito actualizado', 'Carrito'], errores: [404],
});
ep({
  metodo: 'post', ruta: '/carrito/cupon', tag: 'Carrito', resumen: 'Aplicar un cupón',
  descripcion: 'Solo con sesión de Cliente (el límite de usos es por cliente). Aplicar otro cupón reemplaza al anterior: uno por pedido.',
  acceso: 'sesion', roles: ['Cliente'], cuerpo: aplicarCuponSchema, ejemplo: { codigo: 'BIENVENIDO10' },
  ok: [200, 'Carrito con el descuento', 'Carrito'], errores: [404, 409],
});
ep({
  metodo: 'delete', ruta: '/carrito/cupon', tag: 'Carrito', resumen: 'Quitar el cupón',
  acceso: 'sesion', roles: ['Cliente'], ok: [200, 'Carrito sin descuento', 'Carrito'],
});
ep({
  metodo: 'post', ruta: '/carrito/fusionar', tag: 'Carrito', resumen: 'Fusionar el carrito de invitado con el del cliente',
  descripcion:
    'Se llama justo después de iniciar sesión, con la cabecera `x-carrito-token` del carrito de invitado. Las líneas pasan al cliente ' +
    'o se suman a las que ya tenía (limitadas a la existencia disponible y a 1000).',
  acceso: 'carrito', roles: ['Cliente'], ok: [200, 'Carrito del cliente', 'Carrito'], errores: [400],
});

// ───────────────────────────── Direcciones
ep({
  metodo: 'get', ruta: '/direcciones', tag: 'Direcciones', resumen: 'Mis direcciones de entrega',
  acceso: 'sesion', roles: ['Cliente'], ok: [200, 'Lista de direcciones'],
});
ep({
  metodo: 'post', ruta: '/direcciones', tag: 'Direcciones', resumen: 'Crear una dirección',
  acceso: 'sesion', roles: ['Cliente'], cuerpo: crearDireccionSchema,
  ejemplo: { direccion: '10a calle 5-33', zona: '4', municipio: 'Asunción Mita', departamento: 'Jutiapa', referencia: 'Frente al parque' },
  ok: [201, 'Dirección creada', 'IDDireccion'],
});
ep({
  metodo: 'delete', ruta: '/direcciones/{id}', tag: 'Direcciones', resumen: 'Desactivar una dirección',
  descripcion: 'No se borra: los pedidos anteriores siguen apuntando a ella. Responde 403 si la dirección es de otro cliente.',
  acceso: 'sesion', roles: ['Cliente'], ok: [204, 'Dirección desactivada'], errores: [400, 404],
});

// ───────────────────────────── Checkout
ep({
  metodo: 'post', ruta: '/checkout/reservar', tag: 'Checkout', resumen: 'Paso 1: reservar la existencia por 15 minutos',
  descripcion:
    'Congela precio y existencia del carrito. Si dos clientes quieren la última unidad, solo uno la reserva. ' +
    'El procedimiento bloquea las variantes en orden fijo (sin deadlocks) y reintenta si SQL Server aborta por deadlock.',
  acceso: 'sesion', roles: ['Cliente'], ok: [200, 'Reservas y fecha de vencimiento', 'Reserva'], errores: [400, 409, 503],
});
ep({
  metodo: 'post', ruta: '/checkout/pagar', tag: 'Checkout', resumen: 'Paso 2: pagar y crear el pedido (idempotente)',
  descripcion:
    'El cliente genera UNA llave UUID por intento de pago y la reutiliza si reintenta (doble clic, falla de red). ' +
    'La misma llave devuelve el pedido ya creado (200, `repetido: true`) sin cobrar de nuevo; una llave nueva con el carrito ya consumido falla. ' +
    'El pago es SIMULADO (referencia `SIM-...`). Todo ocurre en una transacción: pedido, pago, kardex, cupón y bitácora.',
  acceso: 'sesion', roles: ['Cliente'], cuerpo: pagarSchema,
  ejemplo: { idDireccion: 1, llaveIdempotencia: '3f2b8c1e-5d4a-4b7e-9c1a-2d6e8f0a1b3c', metodoPago: 'TARJETA' },
  ok: [201, 'Pedido creado (200 si la llave ya existía)', 'PedidoCreado'], errores: [400, 403, 409, 503],
});

// ───────────────────────────── Pedidos
ep({
  metodo: 'get', ruta: '/pedidos/estados', tag: 'Pedidos', resumen: 'Estados de pedido (para filtros)',
  acceso: 'sesion', roles: ['Cliente', 'Operador', 'Administrador'], ok: [200, 'Lista de estados'],
});
ep({
  metodo: 'get', ruta: '/pedidos/mios', tag: 'Pedidos', resumen: 'Mis pedidos',
  acceso: 'sesion', roles: ['Cliente'], consulta: misPedidosQuerySchema, ok: [200, 'Página de pedidos', 'Pagina'],
});
ep({
  metodo: 'get', ruta: '/pedidos', tag: 'Pedidos', resumen: 'Listar todos los pedidos',
  descripcion: 'Filtros por estado, cliente, rango de fechas y orden; paginación en el servidor.',
  acceso: 'sesion', roles: ['Operador', 'Administrador'], consulta: listarPedidosQuerySchema, ok: [200, 'Página de pedidos', 'Pagina'],
});
ep({
  metodo: 'get', ruta: '/pedidos/{id}', tag: 'Pedidos', resumen: 'Detalle de un pedido',
  descripcion: 'Un cliente solo puede ver los suyos (otro recibe 403). El personal ve todos. Lo decide el procedimiento almacenado.',
  acceso: 'sesion', roles: ['Cliente (dueño)', 'Operador', 'Administrador'], ok: [200, 'Pedido, líneas, historial y pagos', 'DetallePedido'], errores: [404],
});
ep({
  metodo: 'patch', ruta: '/pedidos/{id}/estado', tag: 'Pedidos', resumen: 'Avanzar el estado del pedido',
  descripcion:
    'Solo admite En preparación, Despachado y Entregado. Pagado, Cancelado y Devuelto tienen su propia vía porque tienen efectos ' +
    '(pago, reintegro de existencia, reembolso). Las transiciones se validan en el procedimiento y en un trigger.',
  acceso: 'sesion', roles: ['Operador', 'Administrador'], cuerpo: avanzarEstadoSchema, ejemplo: { estado: 'En preparación', comentario: 'Se empaca el pedido' },
  ok: [200, 'Pedido actualizado'], errores: [404, 409],
});
ep({
  metodo: 'post', ruta: '/pedidos/{id}/cancelar', tag: 'Pedidos', resumen: 'Cancelar un pedido',
  descripcion:
    'Posible mientras no esté despachado. Reintegra la existencia (movimientos de devolución en el kardex), marca el pago como reembolsado, ' +
    'registra el motivo en el historial y en la bitácora. El cliente cancela los suyos; el personal puede cancelar cualquiera.',
  acceso: 'sesion', roles: ['Cliente (dueño)', 'Operador', 'Administrador'], cuerpo: cancelarPedidoSchema, ejemplo: { motivo: 'Cambié de opinión' },
  ok: [200, 'Pedido cancelado'], errores: [403, 404, 409],
});
ep({
  metodo: 'post', ruta: '/pedidos/{id}/devoluciones', tag: 'Pedidos', resumen: 'Registrar una devolución total o parcial',
  descripcion:
    'Solo pedidos entregados o con devolución parcial previa. Nunca se devuelve más de lo vendido por línea. ' +
    'El reembolso se calcula de forma acumulada para que los centavos siempre cuadren. Las líneas viajan en un parámetro con valor de tabla (TVP).',
  acceso: 'sesion', roles: ['Operador', 'Administrador'], cuerpo: devolucionSchema,
  ejemplo: { motivo: 'Talla incorrecta', lineas: [{ idPedidoDetalle: 1, cantidad: 1 }] },
  ok: [201, 'Devolución registrada con el monto reembolsado'], errores: [404, 409],
});

// ───────────────────────────── Inventario
ep({
  metodo: 'get', ruta: '/inventario/existencias', tag: 'Inventario', resumen: 'Existencias por variante',
  acceso: 'sesion', roles: ['Operador', 'Administrador'], consulta: existenciasQuerySchema, ok: [200, 'Página de existencias', 'Pagina'],
});
ep({
  metodo: 'get', ruta: '/inventario/variantes/{id}/kardex', tag: 'Inventario', resumen: 'Kardex de una variante',
  descripcion: 'Movimientos con signo (entradas positivas, salidas negativas) y la existencia resultante tras cada uno.',
  acceso: 'sesion', roles: ['Operador', 'Administrador'], consulta: kardexQuerySchema, ok: [200, 'Página de movimientos', 'Pagina'], errores: [404],
});
ep({
  metodo: 'post', ruta: '/inventario/ajustes', tag: 'Inventario', resumen: 'Ajuste manual o entrada puntual',
  acceso: 'sesion', roles: ['Operador', 'Administrador'], cuerpo: ajusteSchema,
  ejemplo: { idVariante: 15, tipo: 'AJUSTE', cantidad: 1, motivo: 'Corrección de conteo' }, ok: [201, 'Movimiento registrado'], errores: [404, 409],
});
ep({
  metodo: 'post', ruta: '/inventario/entradas', tag: 'Inventario', resumen: 'Registrar entradas de varias variantes',
  descripcion: 'Un solo envío con varias variantes (TVP) y una sola transacción: si una falla, no se registra ninguna.',
  acceso: 'sesion', roles: ['Operador', 'Administrador'], cuerpo: entradasSchema,
  ejemplo: { motivo: 'Compra a proveedor', entradas: [{ idVariante: 15, cantidad: 5 }] }, ok: [201, 'Entradas registradas'], errores: [404, 409],
});
ep({
  metodo: 'get', ruta: '/inventario/verificar', tag: 'Inventario', resumen: 'Verificar integridad (existencia = suma del kardex)',
  acceso: 'sesion', roles: ['Administrador'], ok: [200, 'Resultado de la verificación', 'Verificacion'],
});
ep({
  metodo: 'post', ruta: '/inventario/liberar-reservas', tag: 'Inventario', resumen: 'Liberar reservas vencidas',
  acceso: 'sesion', roles: ['Administrador'], ok: [200, 'Cantidad de reservas liberadas'],
});

// ───────────────────────────── Administración
ep({ metodo: 'get', ruta: '/usuarios', tag: 'Usuarios', resumen: 'Listar usuarios', acceso: 'sesion', roles: ['Administrador'], consulta: listarUsuariosQuerySchema, ok: [200, 'Página de usuarios', 'Pagina'] });
ep({
  metodo: 'post', ruta: '/usuarios', tag: 'Usuarios', resumen: 'Crear un usuario con cualquier rol', acceso: 'sesion', roles: ['Administrador'], cuerpo: crearUsuarioSchema,
  ejemplo: { email: 'nuevo@shopcart.test', nombreCompleto: 'Operador Nuevo', password: 'Contraseña123!', rol: 'Operador' }, ok: [201, 'Usuario creado'], errores: [409],
});
ep({
  metodo: 'patch', ruta: '/usuarios/{id}/estado', tag: 'Usuarios', resumen: 'Activar o desactivar un usuario',
  descripcion: 'No se borran usuarios. Un administrador no puede desactivarse a sí mismo. Al desactivar se revocan sus refresh tokens.',
  acceso: 'sesion', roles: ['Administrador'], cuerpo: cambiarEstadoUsuarioSchema, ejemplo: { activo: false }, ok: [204, 'Estado actualizado'], errores: [404, 409],
});

ep({ metodo: 'get', ruta: '/categorias', tag: 'Categorías', resumen: 'Listar categorías (incluye inactivas)', acceso: 'sesion', roles: ['Administrador'], ok: [200, 'Lista de categorías'] });
ep({ metodo: 'post', ruta: '/categorias', tag: 'Categorías', resumen: 'Crear una categoría', acceso: 'sesion', roles: ['Administrador'], cuerpo: crearCategoriaSchema, ok: [201, 'Categoría creada'], errores: [409] });
ep({ metodo: 'put', ruta: '/categorias/{id}', tag: 'Categorías', resumen: 'Actualizar una categoría', acceso: 'sesion', roles: ['Administrador'], cuerpo: actualizarCategoriaSchema, ok: [204, 'Categoría actualizada'], errores: [404, 409] });

ep({ metodo: 'get', ruta: '/productos/{id}', tag: 'Productos', resumen: 'Detalle de producto para el backoffice (incluye inactivos)', acceso: 'sesion', roles: ['Administrador'], ok: [200, 'Producto y variantes'], errores: [404] });
ep({
  metodo: 'post', ruta: '/productos', tag: 'Productos', resumen: 'Crear un producto con sus variantes',
  descripcion: 'Las variantes viajan en un TVP: o se crean todas o ninguna. El SKU es único (sin distinguir mayúsculas).',
  acceso: 'sesion', roles: ['Administrador'], cuerpo: crearProductoSchema,
  ejemplo: {
    nombreProducto: 'Camisa Lino', idCategoria: 1, descripcion: 'Camisa de lino',
    variantes: [{ sku: 'LINO-M-BE', talla: 'M', color: 'Beige', precio: 189.0, existenciaInicial: 10 }],
  },
  ok: [201, 'Producto creado'], errores: [409],
});
ep({ metodo: 'put', ruta: '/productos/{id}', tag: 'Productos', resumen: 'Actualizar un producto', acceso: 'sesion', roles: ['Administrador'], cuerpo: actualizarProductoSchema, ok: [204, 'Producto actualizado'], errores: [404] });
ep({ metodo: 'post', ruta: '/productos/{id}/variantes', tag: 'Productos', resumen: 'Agregar una variante', acceso: 'sesion', roles: ['Administrador'], cuerpo: varianteNuevaSchema, ok: [201, 'Variante creada'], errores: [404, 409] });
ep({ metodo: 'put', ruta: '/variantes/{id}', tag: 'Productos', resumen: 'Actualizar una variante', acceso: 'sesion', roles: ['Administrador'], cuerpo: actualizarVarianteSchema, ok: [204, 'Variante actualizada'], errores: [404] });
ep({
  metodo: 'patch', ruta: '/variantes/{id}/precio', tag: 'Productos', resumen: 'Cambiar el precio de una variante',
  descripcion: 'Queda registrado en la bitácora con el precio anterior y el nuevo. Un precio con más de 2 decimales se rechaza.',
  acceso: 'sesion', roles: ['Administrador'], cuerpo: cambiarPrecioSchema, ejemplo: { precio: 129.5 }, ok: [204, 'Precio actualizado'], errores: [404],
});

ep({ metodo: 'get', ruta: '/cupones', tag: 'Cupones', resumen: 'Listar cupones', acceso: 'sesion', roles: ['Administrador'], consulta: listarCuponesQuerySchema, ok: [200, 'Página de cupones', 'Pagina'] });
ep({
  metodo: 'post', ruta: '/cupones', tag: 'Cupones', resumen: 'Crear un cupón', acceso: 'sesion', roles: ['Administrador'], cuerpo: crearCuponSchema,
  ejemplo: {
    codigo: 'NAVIDAD10', descripcion: '10 % de descuento', tipo: 'PORCENTAJE', valor: 10, fechaInicio: '2026-12-01', fechaFin: '2026-12-31',
    montoMinimo: 100, limiteUsosTotal: 500, limiteUsosPorCliente: 1,
  },
  ok: [201, 'Cupón creado'], errores: [409],
});
ep({ metodo: 'put', ruta: '/cupones/{id}', tag: 'Cupones', resumen: 'Actualizar un cupón', acceso: 'sesion', roles: ['Administrador'], cuerpo: actualizarCuponSchema, ok: [204, 'Cupón actualizado'], errores: [404] });

ep({
  metodo: 'get', ruta: '/reportes/ventas', tag: 'Reportes', resumen: 'Ventas por período',
  descripcion: 'Agrupadas por día, semana o mes en HORA DE GUATEMALA. Excluye pedidos pendientes de pago, cancelados y devueltos por completo; resta devoluciones parciales.',
  acceso: 'sesion', roles: ['Administrador'], consulta: ventasQuerySchema, ok: [200, 'Serie de ventas'], errores: [400],
});
ep({ metodo: 'get', ruta: '/reportes/categorias', tag: 'Reportes', resumen: 'Ventas por categoría', acceso: 'sesion', roles: ['Administrador'], consulta: rangoQuerySchema, ok: [200, 'Ventas por categoría'], errores: [400] });
ep({ metodo: 'get', ruta: '/reportes/top-productos', tag: 'Reportes', resumen: 'Productos más vendidos', acceso: 'sesion', roles: ['Administrador'], consulta: topProductosQuerySchema, ok: [200, 'Ranking'], errores: [400] });
ep({ metodo: 'get', ruta: '/reportes/resumen', tag: 'Reportes', resumen: 'Resumen del dashboard (ventas, pedidos, ticket promedio, abandono)', acceso: 'sesion', roles: ['Administrador'], consulta: resumenQuerySchema, ok: [200, 'Indicadores'], errores: [400] });
ep({ metodo: 'get', ruta: '/reportes/carritos-abandonados', tag: 'Reportes', resumen: 'Carritos abandonados', acceso: 'sesion', roles: ['Administrador'], consulta: abandonadosQuerySchema, ok: [200, 'Página de carritos', 'Pagina'] });

ep({
  metodo: 'get', ruta: '/bitacora', tag: 'Bitácora', resumen: 'Consultar la bitácora de auditoría',
  descripcion: 'Solo lectura: la bitácora es inmutable (triggers INSTEAD OF impiden actualizar y borrar). Guarda quién, cuándo, qué y los valores anterior y nuevo en JSON.',
  acceso: 'sesion', roles: ['Administrador'], consulta: bitacoraQuerySchema, ok: [200, 'Página de registros', 'Pagina'],
});

// ───────────────────────────── Armado del documento
const objeto = (propiedades: Record<string, Json>, requeridos?: string[]): Json => ({
  type: 'object',
  properties: propiedades,
  ...(requeridos ? { required: requeridos } : {}),
});
const cualquiera: Json = { type: 'object', additionalProperties: true };

const ESQUEMAS: Record<string, Json> = {
  Error: objeto(
    {
      error: objeto(
        {
          codigo: { type: 'string', example: 'VALIDACION' },
          mensaje: { type: 'string', example: 'Los datos enviados no son válidos.' },
          detalles: { description: 'Solo en errores de validación: lista de { campo, mensaje }.', type: 'array', items: cualquiera },
        },
        ['codigo', 'mensaje'],
      ),
    },
    ['error'],
  ),
  Salud: objeto({ estado: { type: 'string', example: 'ok' }, baseDeDatos: { type: 'string', example: 'ok' } }),
  UsuarioRegistrado: objeto({
    usuario: objeto({ IDUsuario: { type: 'integer' }, Email: { type: 'string' }, NombreCompleto: { type: 'string' }, NombreRol: { type: 'string' } }),
  }),
  Tokens: objeto({ accessToken: { type: 'string', description: 'JWT HS256, 15 minutos.' }, refreshToken: { type: 'string', description: 'Opaco, 7 días, un solo uso.' } }),
  Sesion: objeto({
    usuario: objeto({ IDUsuario: { type: 'integer' }, Email: { type: 'string' }, NombreCompleto: { type: 'string' }, Activo: { type: 'boolean' }, IDRol: { type: 'integer' }, NombreRol: { type: 'string' } }),
    accessToken: { type: 'string' },
    refreshToken: { type: 'string' },
  }),
  PerfilRespuesta: objeto({ usuario: cualquiera }),
  IDDireccion: objeto({ IDDireccion: { type: 'integer' } }),
  Pagina: objeto({
    datos: { type: 'array', items: cualquiera },
    total: { type: 'integer' },
    pagina: { type: 'integer' },
    tamanoPagina: { type: 'integer' },
    totalPaginas: { type: 'integer' },
  }),
  Carrito: objeto({
    carrito: cualquiera,
    lineas: { type: 'array', items: cualquiera },
    totales: cualquiera,
    tokenInvitado: { type: 'string', format: 'uuid', nullable: true, description: 'Solo para invitados: se envía luego en la cabecera x-carrito-token.' },
  }),
  Reserva: objeto({ reservas: { type: 'array', items: cualquiera }, venceEn: { type: 'string', format: 'date-time', nullable: true } }),
  PedidoCreado: objeto({
    idPedido: { type: 'integer' },
    repetido: { type: 'boolean', description: 'true si la llave de idempotencia ya existía.' },
    pedido: cualquiera,
    lineas: { type: 'array', items: cualquiera },
    historial: { type: 'array', items: cualquiera },
    pagos: { type: 'array', items: cualquiera },
  }),
  DetallePedido: objeto({
    pedido: cualquiera,
    lineas: { type: 'array', items: cualquiera },
    historial: { type: 'array', items: cualquiera },
    pagos: { type: 'array', items: cualquiera },
  }),
  Verificacion: objeto({ coincide: { type: 'boolean' }, diferencias: { type: 'array', items: cualquiera } }),
};

const ERRORES_ESTANDAR: Record<number, string> = {
  400: 'Datos inválidos (código VALIDACION) o regla de negocio incumplida.',
  401: 'Falta el token, es inválido/expiró, o las credenciales son incorrectas.',
  403: 'Sin permisos para esta acción (rol insuficiente o recurso de otro usuario).',
  404: 'El recurso no existe.',
  409: 'Conflicto con el estado actual (duplicado, transición no permitida, existencia insuficiente…).',
  429: 'Demasiadas solicitudes: se superó el límite por IP.',
  503: 'Servicio ocupado (tiempo de bloqueo agotado) o base de datos no disponible. Se puede reintentar.',
};

const refError = (codigo: number): Json => ({ $ref: `#/components/responses/E${codigo}` });

function seguridad(acceso: Acceso): Json[] | undefined {
  switch (acceso) {
    case 'publico': return [];
    case 'sesion': return [{ bearerAuth: [] }];
    case 'carrito': return [{ bearerAuth: [], carritoToken: [] }];
    case 'carritoOpcional': return [{ bearerAuth: [] }, { carritoToken: [] }];
  }
}

function construirOperacion(e: Endpoint): Json {
  const parametros: Json[] = [];
  for (const [, nombre] of e.ruta.matchAll(/\{(\w+)\}/g)) {
    parametros.push({ name: nombre, in: 'path', required: true, schema: { type: 'integer', minimum: 1 } });
  }
  if (e.consulta) parametros.push(...parametrosDeConsulta(e.consulta));
  if (e.acceso === 'carrito' || e.acceso === 'carritoOpcional') {
    parametros.push({
      name: 'x-carrito-token', in: 'header', required: false, schema: { type: 'string', format: 'uuid' },
      description: 'Token del carrito de invitado (lo entrega GET /carrito la primera vez).',
    });
  }

  const [codigoOk, descripcionOk, esquemaOk] = e.ok;
  const respuestas: Record<string, Json> = {
    [String(codigoOk)]: {
      description: descripcionOk,
      ...(esquemaOk ? { content: { 'application/json': { schema: { $ref: `#/components/schemas/${esquemaOk}` } } } } : {}),
    },
  };

  const errores = new Set<number>(e.errores ?? []);
  if (e.cuerpo || e.consulta) errores.add(400);
  if (e.acceso !== 'publico') errores.add(401);
  if (e.roles && e.acceso !== 'carritoOpcional') errores.add(403);
  if (e.ruta.includes('{')) errores.add(404);
  for (const c of [...errores].sort()) respuestas[String(c)] = refError(c);
  if (e.ruta === '/checkout/pagar') {
    respuestas['200'] = {
      description: 'La llave de idempotencia ya existía: se devuelve el pedido anterior sin cobrar de nuevo (`repetido: true`).',
      content: { 'application/json': { schema: { $ref: '#/components/schemas/PedidoCreado' } } },
    };
  }

  const descripcion = [e.descripcion, e.roles ? `**Roles:** ${e.roles.join(', ')}.` : undefined].filter(Boolean).join('\n\n');
  return {
    tags: [e.tag],
    summary: e.resumen,
    ...(descripcion ? { description: descripcion } : {}),
    ...(seguridad(e.acceso) ? { security: seguridad(e.acceso) } : {}),
    ...(parametros.length ? { parameters: parametros } : {}),
    ...(e.cuerpo
      ? {
          requestBody: {
            required: true,
            content: {
              'application/json': {
                schema: aJsonSchema(e.cuerpo),
                ...(e.ejemplo !== undefined ? { example: e.ejemplo } : {}),
              },
            },
          },
        }
      : {}),
    responses: respuestas,
  };
}

const DESCRIPCION_API = `
API REST del carrito de compras **ShopCart** (Tech Challenge 360).

**Arquitectura:** rutas → controladores → servicios → procedimientos almacenados → tablas. Todo acceso a datos es por procedimientos almacenados.

**Autenticación:** access token JWT de 15 minutos en \`Authorization: Bearer <token>\` y refresh token opaco de 7 días con rotación y detección de reutilización.
El carrito de un invitado se identifica con la cabecera \`x-carrito-token\`.

**Formato de error (siempre el mismo):** \`{ "error": { "codigo": "...", "mensaje": "...", "detalles": [...] } }\`.

**Cuentas de prueba** (contraseña \`Prueba123!\`): \`admin@shopcart.test\` (Administrador), \`operador@shopcart.test\` (Operador), \`cliente@shopcart.test\` (Cliente).

Para probar en esta página: inicie sesión con **POST /auth/login**, copie el \`accessToken\` y péguelo en **Authorize**.
`.trim();

export function construirOpenApi(urlServidor = '/api'): Json {
  const paths: Record<string, Record<string, Json>> = {};
  for (const e of E) {
    (paths[e.ruta] ??= {})[e.metodo] = construirOperacion(e);
  }

  const respuestas: Record<string, Json> = {};
  for (const [codigo, descripcion] of Object.entries(ERRORES_ESTANDAR)) {
    respuestas[`E${codigo}`] = {
      description: descripcion,
      content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } },
    };
  }

  const tags = [...new Set(E.map((e) => e.tag))].map((name) => ({ name }));

  return {
    openapi: '3.0.3',
    info: { title: 'ShopCart API', version: '1.0.0', description: DESCRIPCION_API },
    servers: [{ url: urlServidor, description: 'Servidor actual' }],
    tags,
    paths,
    components: {
      securitySchemes: {
        bearerAuth: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT', description: 'Access token obtenido en POST /auth/login.' },
        carritoToken: { type: 'apiKey', in: 'header', name: 'x-carrito-token', description: 'Identifica el carrito de un invitado.' },
      },
      responses: respuestas,
      schemas: ESQUEMAS,
    },
  };
}

/** Para las pruebas de la documentación: qué operaciones se documentaron y con qué ejemplo/esquema. */
export const endpointsDocumentados = (): readonly Endpoint[] => E;

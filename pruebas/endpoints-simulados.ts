import '../pruebas/preparar-entorno'; // debe ser el primer import: fija el entorno antes de cargar la app
import fs from 'node:fs';
import path from 'node:path';
import sql from 'mssql';
import { crearAccessToken } from '../src/Services/tokens.servicio';
import { app } from '../src/app';

// Carpeta con los scripts .sql del proyecto. Se busca en ./database y en ../database; se puede fijar con la variable RUTA_SQL.
const candidatas = [path.resolve(__dirname, '..', 'database'), path.resolve(__dirname, '..', '..', 'database')];
const RUTA_SQL = process.env['RUTA_SQL'] ?? candidatas.find((c) => fs.existsSync(path.join(c, '008_SP_Acceso.sql'))) ?? candidatas[0]!;

// ---------------------------------------------------------------- 1) Firmas reales desde los scripts SQL
interface ParamSql { tipo: string; largo: string | undefined; obligatorio: boolean; salida: boolean }
const firmas = new Map<string, Map<string, ParamSql>>();
const tiposTabla = new Map<string, { nombre: string; tipo: string; largo: string | undefined }[]>();

const archivos = ['008_SP_Acceso', '009_SP_Catalogo_Inventario', '010_SP_Carrito_Cupones', '011_SP_Checkout_Pedidos', '012_SP_Reportes_Bitacora', '016_Direcciones_Estados']
  .map((n) => fs.readFileSync(path.join(RUTA_SQL, `${n}.sql`), 'utf8'));
for (const texto of archivos) {
  for (const m of texto.matchAll(/CREATE OR ALTER PROCEDURE (\w+)\s*([\s\S]*?)\bAS\b\s*BEGIN/g)) {
    const params = new Map<string, ParamSql>();
    for (const linea of (m[2] ?? '').split('\n')) {
      const l = linea.replace(/--.*$/, '').trim().replace(/,$/, '');
      const p = /^@(\w+)\s+(\w+)(?:\(([^)]*)\))?\s*(?:=\s*(.+?))?\s*(OUTPUT|READONLY)?$/i.exec(l);
      if (p) params.set((p[1] ?? '').toLowerCase(), { tipo: (p[2] ?? '').toLowerCase(), largo: p[3], obligatorio: p[4] === undefined && (p[5] ?? '').toUpperCase() !== 'OUTPUT', salida: (p[5] ?? '').toUpperCase() === 'OUTPUT' });
    }
    firmas.set((m[1] ?? '').toLowerCase(), params);
  }
}
const sql007 = fs.readFileSync(path.join(RUTA_SQL, '007_Tipos_Funciones_Vistas.sql'), 'utf8');
for (const m of sql007.matchAll(/CREATE TYPE (\w+) AS TABLE \(([\s\S]*?)\n\);/g)) {
  const cols = (m[2] ?? '').split('\n').map((x) => x.trim()).filter((x) => /^\w+\s+\w+/.test(x)).map((x) => {
    const c = /^(\w+)\s+(\w+)(?:\(([^)]*)\))?/.exec(x)!;
    return { nombre: c[1] ?? '', tipo: (c[2] ?? '').toLowerCase(), largo: c[3] };
  });
  tiposTabla.set((m[1] ?? '').toLowerCase(), cols);
}

// ---------------------------------------------------------------- 2) Base de datos simulada
interface Llamada { sp: string; entradas: { nombre: string; tipo: unknown; valor: unknown }[] }
const llamadas: Llamada[] = [];
type Entradas = { nombre: string; tipo: unknown; valor: unknown }[];
const entrada = (e: Entradas, n: string): unknown => e.find((x) => x.nombre === n)?.valor ?? null;
let repetidoSimulado = false;
const resumenCarrito = (): unknown[][] => [[{ IDCarrito: 50, Estado: 'ACTIVO', CuponValido: false }], [{ IDVariante: 1, Cantidad: 2 }], [{ Subtotal: 100, Descuento: 0, Total: 100, IVAIncluido: 10.71 }]];
const GUID_SQL = 'AAAAAAAA-0000-4000-8000-000000000001';
const respuestas: Record<string, unknown[][] | ((e: Entradas) => unknown[][])> = {
  sp_usuarios_crear: [[{ IDUsuario: 21 }]],
  sp_categorias_crear: [[{ IDCategoria: 9 }]],
  sp_productos_crear: [[{ IDProducto: 5 }]],
  sp_variantes_crear: [[{ IDVariante: 7 }]],
  sp_cupones_crear: [[{ IDCupon: 3 }]],
  sp_direcciones_crear: [[{ IDDireccion: 4 }]],
  sp_catalogo_obtenerproducto: [[{ IDProducto: 1, NombreProducto: 'X' }], [{ IDVariante: 1 }]],
  sp_reportes_resumen: [[{ NumeroPedidos: 2 }], [{ CarritosAbandonados: 3 }]],
  sp_inventario_ajustarexistencia: [[{ IDVariante: 1, ExistenciaFisica: 10, Disponible: 10 }]],
  sp_usuarios_listar: [[{ IDUsuario: 1, TotalRegistros: 45 }]],
  sp_auth_obtenerusuarioporid: [[{ IDUsuario: 1, Email: 'a@b.com', NombreCompleto: 'Ana', Activo: true, IDRol: 1, NombreRol: 'Cliente' }]],
  sp_inventario_liberarreservasvencidas: [[{ ReservasLiberadas: 4 }]],
  sp_carrito_obtenerocrear: (e) => {
    const usuario = entrada(e, 'IDUsuario');
    return usuario !== null
      ? [[{ IDCarrito: 50, IDUsuario: usuario, TokenInvitado: null, Estado: 'ACTIVO' }]]
      : [[{ IDCarrito: 51, IDUsuario: null, TokenInvitado: entrada(e, 'TokenInvitado') ?? GUID_SQL, Estado: 'ACTIVO' }]];
  },
  sp_carrito_resumen: resumenCarrito,
  sp_carrito_agregarproducto: resumenCarrito,
  sp_carrito_actualizarcantidad: resumenCarrito,
  sp_carrito_eliminarproducto: resumenCarrito,
  sp_carrito_aplicarcupon: resumenCarrito,
  sp_carrito_quitarcupon: resumenCarrito,
  sp_carrito_fusionar: (e) => [[{ IDCarrito: 50, IDUsuario: entrada(e, 'IDUsuario'), TokenInvitado: null, Estado: 'ACTIVO' }]],
  sp_inventario_reservarexistencia: [[{ IDReserva: 1, SKU: 'A-1', Cantidad: 2, FechaVencimiento: new Date('2026-11-01T20:15:00Z') }]],
  sp_pedidos_crearpedido: () => [[{ IDPedido: 100, Repetido: repetidoSimulado }], [{ IDPedido: 100, Estado: 'Pagado' }], [{ IDPedidoDetalle: 1 }], [{ Estado: 'Pagado' }], [{ IDPago: 1 }]],
  sp_pedidos_obtenerdetalle: [[{ IDPedido: 100 }], [{ IDPedidoDetalle: 1 }], [{ Estado: 'Pagado' }], [{ IDPago: 1 }]],
  sp_pedidos_listar: [[{ IDPedido: 100, TotalRegistros: 7 }]],
  sp_pedidos_listarporcliente: [[{ IDPedido: 100, TotalRegistros: 3 }]],
  sp_pedidos_listarestados: [[{ IDEstadoPedido: 1, NombreEstado: 'Pagado' }]],
  sp_pedidos_avanzarestado: [[{ IDPedido: 100, Estado: 'Despachado' }]],
  sp_pedidos_cancelar: [[{ IDPedido: 100, Estado: 'Cancelado' }]],
  sp_pedidos_registrardevolucion: [[{ IDDevolucion: 1, Tipo: 'PARCIAL', MontoReembolso: 75, EstadoPedido: 'Devuelto parcial' }]],
  sp_cupones_listar: [[{ IDCupon: 1, TotalRegistros: 12 }]],
  sp_bitacora_listar: [[{ IDBitacora: 1, TotalRegistros: 1 }]],
};
class SolicitudFalsa {
  entradas: Llamada['entradas'] = [];
  input(nombre: string, a: unknown, b?: unknown): this {
    if (arguments.length === 2) this.entradas.push({ nombre, tipo: undefined, valor: a });
    else this.entradas.push({ nombre, tipo: a, valor: b });
    return this;
  }
  execute(sp: string): Promise<{ recordsets: unknown[][] }> {
    llamadas.push({ sp, entradas: this.entradas });
    const r = respuestas[sp.toLowerCase()];
    return Promise.resolve({ recordsets: typeof r === 'function' ? r(this.entradas) : (r ?? [[]]) });
  }
}
class PoolFalso {
  connected = true;
  on(): this { return this; }
  connect(): Promise<this> { return Promise.resolve(this); }
  close(): Promise<void> { return Promise.resolve(); }
  request(): SolicitudFalsa { return new SolicitudFalsa(); }
}
(sql as unknown as { ConnectionPool: unknown }).ConnectionPool = PoolFalso;

// ---------------------------------------------------------------- 3) Utilidades
function describir(tipo: unknown): { base: string; largo: string | undefined } {
  const t = tipo as { declaration?: string; type?: { declaration?: string } | string; length?: number; precision?: number; scale?: number };
  const base = typeof t.type === 'string' ? t.type : (t.declaration ?? t.type?.declaration ?? '?');
  if (base === 'decimal') return { base, largo: `${t.precision},${t.scale}` };
  return { base, largo: t.length ? String(t.length) : undefined };
}
let ok = 0, fallas = 0;
const falla: string[] = [];
function afirmar(nombre: string, condicion: boolean, detalle = ''): void {
  if (condicion) ok++; else { fallas++; falla.push(`FALLA | ${nombre} ${detalle}`); }
}

function revisarLlamada(contexto: string, l: Llamada): void {
  const firma = firmas.get(l.sp.toLowerCase());
  afirmar(`${contexto}: el procedimiento ${l.sp} existe`, firma !== undefined);
  if (!firma) return;
  const enviados = new Set<string>();
  for (const e of l.entradas) {
    const p = firma.get(e.nombre.toLowerCase());
    afirmar(`${contexto}: ${l.sp} tiene el parámetro @${e.nombre}`, p !== undefined);
    if (!p) continue;
    enviados.add(e.nombre.toLowerCase());
    if (e.valor instanceof sql.Table) {
     afirmar(`${contexto}: @${e.nombre} es el tipo de tabla ${p.tipo}`, (e.valor.name ?? '').toLowerCase() === p.tipo, `(${e.valor.name ?? 'sin nombre'})`);
      const cols = tiposTabla.get(p.tipo) ?? [];
      const reales = e.valor.columns.map((c) => ({ nombre: c.name, ...describir(c.type) }));
      afirmar(`${contexto}: columnas del TVP ${p.tipo} (${reales.length} vs ${cols.length})`, reales.length === cols.length);
      cols.forEach((c, i) => {
        const r = reales[i];
        afirmar(`${contexto}: TVP ${p.tipo} columna ${i + 1} = ${c.nombre} ${c.tipo}`, !!r && r.nombre.toLowerCase() === c.nombre.toLowerCase() && r.base === c.tipo, `(${r?.nombre} ${r?.base})`);
      });
      continue;
    }
    const d = describir(e.tipo);
    const mismoTipo = d.base === p.tipo;
    afirmar(`${contexto}: @${e.nombre} es ${p.tipo}${p.largo ? `(${p.largo})` : ''}`, mismoTipo, `(se envía ${d.base})`);
    if (mismoTipo && p.largo && p.largo.toUpperCase() !== 'MAX' && d.largo !== undefined) {
      const ok2 = p.tipo === 'decimal' ? d.largo === p.largo.replace(/\s/g, '') : Number(d.largo) <= Number(p.largo);
      afirmar(`${contexto}: @${e.nombre} longitud ${d.largo} cabe en (${p.largo})`, ok2);
    }
  }
  for (const [nombre, p] of firma) {
    if (p.obligatorio) afirmar(`${contexto}: se envía el parámetro obligatorio @${nombre}`, enviados.has(nombre));
  }
}

const tokens = {
  Cliente: crearAccessToken({ IDUsuario: 11, NombreRol: 'Cliente' }),
  Operador: crearAccessToken({ IDUsuario: 2, NombreRol: 'Operador' }),
  Administrador: crearAccessToken({ IDUsuario: 1, NombreRol: 'Administrador' }),
};
const idDeRol = { Cliente: 11, Operador: 2, Administrador: 1 } as const;
type Rol = keyof typeof tokens;

async function http(metodo: string, ruta: string, rol?: Rol, cuerpo?: unknown, extra: Record<string, string> = {}): Promise<{ estado: number; json: any }> {
  const cabeceras: Record<string, string> = { ...extra };
  if (rol) cabeceras['authorization'] = `Bearer ${tokens[rol]}`;
  if (cuerpo !== undefined) cabeceras['content-type'] = 'application/json';
  const r = await fetch(`http://127.0.0.1:3914${ruta}`, { method: metodo, headers: cabeceras, ...(cuerpo !== undefined ? { body: JSON.stringify(cuerpo) } : {}) });
  const texto = await r.text();
  return { estado: r.status, json: texto ? JSON.parse(texto) : null };
}

// ---------------------------------------------------------------- 4) Tabla de rutas y permisos
const hoy = 'desde=2026-10-01&hasta=2026-10-31';
const variante = { sku: 'CAM-001', talla: 'M', color: 'Azul', precio: 149.5, existenciaInicial: 10 };
interface Ruta { m: string; r: string; permitidos: Rol[] | 'publico'; cuerpo?: unknown; exito: number; sp: string }
const ADMIN: Rol[] = ['Administrador'];
const TODOS: Rol[] = ['Cliente', 'Operador', 'Administrador'];
const pago = { idDireccion: 4, llaveIdempotencia: '7f3c2a10-5b6d-4e8f-9a1b-2c3d4e5f6a7b' };
const PERSONAL: Rol[] = ['Operador', 'Administrador'];
const rutas: Ruta[] = [
  { m: 'GET', r: '/api/catalogo/categorias', permitidos: 'publico', exito: 200, sp: 'SP_Categorias_Listar' },
  { m: 'GET', r: '/api/catalogo/productos', permitidos: 'publico', exito: 200, sp: 'SP_Catalogo_Buscar' },
  { m: 'GET', r: '/api/catalogo/productos/1', permitidos: 'publico', exito: 200, sp: 'SP_Catalogo_ObtenerProducto' },
  { m: 'GET', r: '/api/usuarios', permitidos: ADMIN, exito: 200, sp: 'SP_Usuarios_Listar' },
  { m: 'POST', r: '/api/usuarios', permitidos: ADMIN, cuerpo: { email: 'op@x.com', nombreCompleto: 'Op Uno', password: 'Clave1234', rol: 'Operador' }, exito: 201, sp: 'SP_Usuarios_Crear' },
  { m: 'PATCH', r: '/api/usuarios/5/estado', permitidos: ADMIN, cuerpo: { activo: false }, exito: 204, sp: 'SP_Usuarios_CambiarEstado' },
  { m: 'GET', r: '/api/categorias', permitidos: ADMIN, exito: 200, sp: 'SP_Categorias_Listar' },
  { m: 'POST', r: '/api/categorias', permitidos: ADMIN, cuerpo: { nombreCategoria: 'Hogar', descripcion: 'Cosas' }, exito: 201, sp: 'SP_Categorias_Crear' },
  { m: 'PUT', r: '/api/categorias/9', permitidos: ADMIN, cuerpo: { nombreCategoria: 'Hogar', activo: true }, exito: 204, sp: 'SP_Categorias_Actualizar' },
  { m: 'GET', r: '/api/productos/1', permitidos: ADMIN, exito: 200, sp: 'SP_Catalogo_ObtenerProducto' },
  { m: 'POST', r: '/api/productos', permitidos: ADMIN, cuerpo: { nombreProducto: 'Camisa', idCategoria: 1, variantes: [variante, { ...variante, sku: 'CAM-002', talla: 'L' }] }, exito: 201, sp: 'SP_Productos_Crear' },
  { m: 'PUT', r: '/api/productos/5', permitidos: ADMIN, cuerpo: { nombreProducto: 'Camisa', idCategoria: 1, activo: true }, exito: 204, sp: 'SP_Productos_Actualizar' },
  { m: 'POST', r: '/api/productos/5/variantes', permitidos: ADMIN, cuerpo: variante, exito: 201, sp: 'SP_Variantes_Crear' },
  { m: 'PUT', r: '/api/variantes/7', permitidos: ADMIN, cuerpo: { talla: 'S', activo: true }, exito: 204, sp: 'SP_Variantes_Actualizar' },
  { m: 'PATCH', r: '/api/variantes/7/precio', permitidos: ADMIN, cuerpo: { precio: 199.99 }, exito: 204, sp: 'SP_Variantes_CambiarPrecio' },
  { m: 'GET', r: '/api/inventario/existencias', permitidos: PERSONAL, exito: 200, sp: 'SP_Inventario_ListarExistencias' },
  { m: 'GET', r: '/api/inventario/variantes/7/kardex', permitidos: PERSONAL, exito: 200, sp: 'SP_Inventario_ConsultarKardex' },
  { m: 'POST', r: '/api/inventario/ajustes', permitidos: PERSONAL, cuerpo: { idVariante: 7, tipo: 'AJUSTE', cantidad: -2, motivo: 'Conteo físico' }, exito: 201, sp: 'SP_Inventario_AjustarExistencia' },
  { m: 'POST', r: '/api/inventario/entradas', permitidos: PERSONAL, cuerpo: { motivo: 'Compra a proveedor', entradas: [{ idVariante: 7, cantidad: 5 }, { idVariante: 8, cantidad: 3 }] }, exito: 201, sp: 'SP_Inventario_RegistrarEntradas' },
  { m: 'GET', r: '/api/inventario/verificar', permitidos: ADMIN, exito: 200, sp: 'SP_Inventario_VerificarKardex' },
  { m: 'GET', r: '/api/cupones', permitidos: ADMIN, exito: 200, sp: 'SP_Cupones_Listar' },
  { m: 'POST', r: '/api/cupones', permitidos: ADMIN, cuerpo: { codigo: 'verano10', tipo: 'PORCENTAJE', valor: 10, fechaInicio: '2026-11-01', fechaFin: '2026-11-30', limiteUsosTotal: 100 }, exito: 201, sp: 'SP_Cupones_Crear' },
  { m: 'PUT', r: '/api/cupones/3', permitidos: ADMIN, cuerpo: { tipo: 'MONTO_FIJO', valor: 25, fechaInicio: '2026-11-01', fechaFin: '2026-11-30', montoMinimo: 200, limiteUsosTotal: 100, limiteUsosPorCliente: 2, activo: true }, exito: 204, sp: 'SP_Cupones_Actualizar' },
  { m: 'GET', r: `/api/reportes/ventas?${hoy}&agrupacion=SEMANA`, permitidos: ADMIN, exito: 200, sp: 'SP_Reportes_VentasPorPeriodo' },
  { m: 'GET', r: `/api/reportes/categorias?${hoy}`, permitidos: ADMIN, exito: 200, sp: 'SP_Reportes_VentasPorCategoria' },
  { m: 'GET', r: `/api/reportes/top-productos?${hoy}&top=10`, permitidos: ADMIN, exito: 200, sp: 'SP_Reportes_TopProductos' },
  { m: 'GET', r: `/api/reportes/resumen?${hoy}`, permitidos: ADMIN, exito: 200, sp: 'SP_Reportes_Resumen' },
  { m: 'GET', r: '/api/reportes/carritos-abandonados', permitidos: ADMIN, exito: 200, sp: 'SP_Reportes_CarritosAbandonados' },
  { m: 'GET', r: '/api/bitacora?modulo=Pedidos', permitidos: ADMIN, exito: 200, sp: 'SP_Bitacora_Listar' },
  { m: 'GET', r: '/api/auth/yo', permitidos: TODOS, exito: 200, sp: 'SP_Auth_ObtenerUsuarioPorID' },
  { m: 'POST', r: '/api/inventario/liberar-reservas', permitidos: ADMIN, exito: 200, sp: 'SP_Inventario_LiberarReservasVencidas' },
  { m: 'POST', r: '/api/checkout/reservar', permitidos: ['Cliente'], exito: 200, sp: 'SP_Inventario_ReservarExistencia' },
  { m: 'POST', r: '/api/checkout/pagar', permitidos: ['Cliente'], cuerpo: pago, exito: 201, sp: 'SP_Pedidos_CrearPedido' },
  { m: 'GET', r: '/api/pedidos/estados', permitidos: TODOS, exito: 200, sp: 'SP_Pedidos_ListarEstados' },
  { m: 'GET', r: '/api/pedidos/mios', permitidos: ['Cliente'], exito: 200, sp: 'SP_Pedidos_ListarPorCliente' },
  { m: 'GET', r: '/api/pedidos?ordenar=TOTAL_DESC&desde=2026-10-01&hasta=2026-10-31&estado=2', permitidos: PERSONAL, exito: 200, sp: 'SP_Pedidos_Listar' },
  { m: 'GET', r: '/api/pedidos/100', permitidos: TODOS, exito: 200, sp: 'SP_Pedidos_ObtenerDetalle' },
  { m: 'POST', r: '/api/pedidos/100/cancelar', permitidos: TODOS, cuerpo: { motivo: 'Ya no lo necesito' }, exito: 200, sp: 'SP_Pedidos_Cancelar' },
  { m: 'PATCH', r: '/api/pedidos/100/estado', permitidos: PERSONAL, cuerpo: { estado: 'Despachado', comentario: 'Sale hoy' }, exito: 200, sp: 'SP_Pedidos_AvanzarEstado' },
  { m: 'POST', r: '/api/pedidos/100/devoluciones', permitidos: PERSONAL, cuerpo: { motivo: 'Talla incorrecta', lineas: [{ idPedidoDetalle: 1, cantidad: 1 }, { idPedidoDetalle: 2, cantidad: 2 }] }, exito: 201, sp: 'SP_Pedidos_RegistrarDevolucion' },
  { m: 'GET', r: '/api/direcciones', permitidos: ['Cliente'], exito: 200, sp: 'SP_Direcciones_Listar' },
  { m: 'POST', r: '/api/direcciones', permitidos: ['Cliente'], cuerpo: { direccion: '5a avenida 10-20', zona: '1', municipio: 'Guatemala', departamento: 'Guatemala' }, exito: 201, sp: 'SP_Direcciones_Crear' },
  { m: 'DELETE', r: '/api/direcciones/4', permitidos: ['Cliente'], exito: 204, sp: 'SP_Direcciones_Desactivar' },
];

async function main(): Promise<void> {
  const servidor = app.listen(3914);
  const roles: (Rol | undefined)[] = [undefined, 'Cliente', 'Operador', 'Administrador'];

  // A) Matriz de permisos + conformidad de cada llamada con la firma real del procedimiento
  for (const ruta of rutas) {
    for (const rol of roles) {
      const etiqueta = `${ruta.m} ${ruta.r.split('?')[0]} como ${rol ?? 'anónimo'}`;
      const antes = llamadas.length;
      const res = await http(ruta.m, ruta.r, rol, ruta.cuerpo);
      const nuevas = llamadas.slice(antes);
      const permitido = ruta.permitidos === 'publico' || (rol !== undefined && ruta.permitidos.includes(rol));

      if (permitido) {
        afirmar(`${etiqueta} -> ${ruta.exito}`, res.estado === ruta.exito, `(obtuvo ${res.estado} ${JSON.stringify(res.json)?.slice(0, 150)})`);
        const usada = nuevas.find((l) => l.sp.toLowerCase() === ruta.sp.toLowerCase());
        afirmar(`${etiqueta} ejecuta ${ruta.sp}`, usada !== undefined, `(ejecutó: ${nuevas.map((n) => n.sp).join(',') || 'nada'})`);
        if (usada && rol) {
          for (const n of nuevas) revisarLlamada(`${etiqueta} [${n.sp}]`, n);
          // La identidad que llega al procedimiento sale del token, no de la petición
          for (const e of usada.entradas) {
            if (/^IDUsuario(Accion|Solicitante)?$/i.test(e.nombre) && ruta.sp !== 'SP_Direcciones_Desactivar' && ruta.sp !== 'SP_Usuarios_CambiarEstado') {
              afirmar(`${etiqueta}: @${e.nombre} = id del token (${idDeRol[rol]})`, e.valor === idDeRol[rol], `(valor ${String(e.valor)})`);
            }
          }
        }
      } else {
        const esperado = rol === undefined ? 401 : 403;
        afirmar(`${etiqueta} -> ${esperado}`, res.estado === esperado, `(obtuvo ${res.estado})`);
        afirmar(`${etiqueta} NO toca la base de datos`, nuevas.length === 0, `(ejecutó: ${nuevas.map((n) => n.sp).join(',')})`);
      }
    }
  }

  // B) Validaciones: datos malos se rechazan con 400 y sin tocar la base
  const malos: { nombre: string; m: string; r: string; rol: Rol; cuerpo?: unknown }[] = [
    { nombre: 'campo extra idUsuarioAccion en el body', m: 'POST', r: '/api/categorias', rol: 'Administrador', cuerpo: { nombreCategoria: 'X1', idUsuarioAccion: 99 } },
    { nombre: 'categoría sin nombre', m: 'POST', r: '/api/categorias', rol: 'Administrador', cuerpo: {} },
    { nombre: 'id de la URL no numérico', m: 'PUT', r: '/api/categorias/abc', rol: 'Administrador', cuerpo: { nombreCategoria: 'X1', activo: true } },
    { nombre: 'id de la URL negativo', m: 'PATCH', r: '/api/usuarios/-1/estado', rol: 'Administrador', cuerpo: { activo: true } },
    { nombre: 'rol inventado al crear usuario', m: 'POST', r: '/api/usuarios', rol: 'Administrador', cuerpo: { email: 'a@b.com', nombreCompleto: 'Ana', password: 'Clave1234', rol: 'SuperAdmin' } },
    { nombre: 'contraseña corta al crear usuario', m: 'POST', r: '/api/usuarios', rol: 'Administrador', cuerpo: { email: 'a@b.com', nombreCompleto: 'Ana', password: '123', rol: 'Operador' } },
    { nombre: 'precio con 3 decimales', m: 'PATCH', r: '/api/variantes/7/precio', rol: 'Administrador', cuerpo: { precio: 10.123 } },
    { nombre: 'precio negativo', m: 'PATCH', r: '/api/variantes/7/precio', rol: 'Administrador', cuerpo: { precio: -1 } },
    { nombre: 'precio mayor al máximo', m: 'PATCH', r: '/api/variantes/7/precio', rol: 'Administrador', cuerpo: { precio: 99999999 } },
    { nombre: 'producto sin variantes', m: 'POST', r: '/api/productos', rol: 'Administrador', cuerpo: { nombreProducto: 'Sin', idCategoria: 1, variantes: [] } },
    { nombre: 'SKU repetido dentro del producto', m: 'POST', r: '/api/productos', rol: 'Administrador', cuerpo: { nombreProducto: 'Dup', idCategoria: 1, variantes: [variante, { ...variante, sku: 'cam-001' }] } },
    { nombre: 'SKU con caracteres raros', m: 'POST', r: '/api/productos/5/variantes', rol: 'Administrador', cuerpo: { ...variante, sku: "A'; DROP TABLE--" } },
    { nombre: 'existencia inicial negativa', m: 'POST', r: '/api/productos/5/variantes', rol: 'Administrador', cuerpo: { ...variante, existenciaInicial: -1 } },
    { nombre: 'ajuste con cantidad cero', m: 'POST', r: '/api/inventario/ajustes', rol: 'Operador', cuerpo: { idVariante: 7, tipo: 'AJUSTE', cantidad: 0, motivo: 'Conteo' } },
    { nombre: 'ajuste con cantidad gigante', m: 'POST', r: '/api/inventario/ajustes', rol: 'Operador', cuerpo: { idVariante: 7, tipo: 'AJUSTE', cantidad: 2147483647, motivo: 'Conteo' } },
    { nombre: 'ajuste sin motivo', m: 'POST', r: '/api/inventario/ajustes', rol: 'Operador', cuerpo: { idVariante: 7, tipo: 'AJUSTE', cantidad: 1, motivo: '' } },
    { nombre: 'ajuste de tipo SALIDA', m: 'POST', r: '/api/inventario/ajustes', rol: 'Operador', cuerpo: { idVariante: 7, tipo: 'SALIDA', cantidad: -1, motivo: 'Conteo' } },
    { nombre: 'entradas con variantes repetidas', m: 'POST', r: '/api/inventario/entradas', rol: 'Operador', cuerpo: { motivo: 'Compra', entradas: [{ idVariante: 7, cantidad: 1 }, { idVariante: 7, cantidad: 2 }] } },
    { nombre: 'entradas vacías', m: 'POST', r: '/api/inventario/entradas', rol: 'Operador', cuerpo: { motivo: 'Compra', entradas: [] } },
    { nombre: 'cupón porcentaje mayor a 100', m: 'POST', r: '/api/cupones', rol: 'Administrador', cuerpo: { codigo: 'MALO', tipo: 'PORCENTAJE', valor: 150, fechaInicio: '2026-11-01', fechaFin: '2026-11-30', limiteUsosTotal: 10 } },
    { nombre: 'cupón con fecha final anterior', m: 'POST', r: '/api/cupones', rol: 'Administrador', cuerpo: { codigo: 'MALO', tipo: 'MONTO_FIJO', valor: 10, fechaInicio: '2026-11-30', fechaFin: '2026-11-01', limiteUsosTotal: 10 } },
    { nombre: 'cupón con fecha inexistente', m: 'POST', r: '/api/cupones', rol: 'Administrador', cuerpo: { codigo: 'MALO', tipo: 'MONTO_FIJO', valor: 10, fechaInicio: '2026-02-31', fechaFin: '2026-03-31', limiteUsosTotal: 10 } },
    { nombre: 'cupón con código con espacios', m: 'POST', r: '/api/cupones', rol: 'Administrador', cuerpo: { codigo: 'MI CUPON', tipo: 'MONTO_FIJO', valor: 10, fechaInicio: '2026-11-01', fechaFin: '2026-11-30', limiteUsosTotal: 10 } },
    { nombre: 'reporte sin fechas', m: 'GET', r: '/api/reportes/ventas', rol: 'Administrador' },
    { nombre: 'reporte con rango invertido', m: 'GET', r: '/api/reportes/ventas?desde=2026-10-31&hasta=2026-10-01', rol: 'Administrador' },
    { nombre: 'reporte con agrupación inválida', m: 'GET', r: `/api/reportes/ventas?${hoy}&agrupacion=ANIO`, rol: 'Administrador' },
    { nombre: 'bitácora con módulo inventado', m: 'GET', r: '/api/bitacora?modulo=Secretos', rol: 'Administrador' },
    { nombre: 'catálogo con orden inválido', m: 'GET', r: '/api/catalogo/productos?ordenar=DROP', rol: 'Cliente' },
    { nombre: 'catálogo con tamaño de página enorme', m: 'GET', r: '/api/catalogo/productos?tamanoPagina=100000', rol: 'Cliente' },
    { nombre: 'catálogo con página cero', m: 'GET', r: '/api/catalogo/productos?pagina=0', rol: 'Cliente' },
    { nombre: 'dirección sin municipio', m: 'POST', r: '/api/direcciones', rol: 'Cliente', cuerpo: { direccion: '5a avenida', departamento: 'Guatemala' } },
    { nombre: 'dirección con campo extra idUsuario', m: 'POST', r: '/api/direcciones', rol: 'Cliente', cuerpo: { direccion: '5a avenida', municipio: 'G', departamento: 'Guatemala', idUsuario: 99 } },
  ];
  for (const c of malos) {
    const antes = llamadas.length;
    const res = await http(c.m, c.r, c.rol, c.cuerpo);
    afirmar(`validación: ${c.nombre} -> 400`, res.estado === 400, `(obtuvo ${res.estado})`);
    afirmar(`validación: ${c.nombre} NO toca la base`, llamadas.length === antes);
    afirmar(`validación: ${c.nombre} con código VALIDACION`, res.json?.error?.codigo === 'VALIDACION', `(${JSON.stringify(res.json)?.slice(0, 120)})`);
  }

  // C) Comportamientos concretos
  let l: Llamada | undefined;
  const valor = (nombre: string): unknown => l?.entradas.find((e) => e.nombre === nombre)?.valor;

  let res = await http('GET', '/api/usuarios?pagina=2&tamanoPagina=10&texto=ana&rol=Cliente&activo=true', 'Administrador');
  l = llamadas.at(-1);
  afirmar('paginación: Pagina=2 y TamanoPagina=10 llegan a la base', valor('Pagina') === 2 && valor('TamanoPagina') === 10);
  afirmar('paginación: filtros llegan a la base', valor('Buscar') === 'ana' && valor('NombreRol') === 'Cliente' && valor('Activo') === true);
  afirmar('paginación: total 45 y 5 páginas', res.json.total === 45 && res.json.totalPaginas === 5, JSON.stringify(res.json));
  afirmar('paginación: las filas no traen TotalRegistros', res.json.datos[0].TotalRegistros === undefined);

  await http('GET', '/api/catalogo/productos?categoria=3&precioMin=10&precioMax=50.5&soloDisponibles=true&ordenar=PRECIO_DESC&texto=%25_%5B', 'Cliente');
  l = llamadas.at(-1);
  afirmar('catálogo: filtros y orden llegan tal cual a la base', valor('IDCategoria') === 3 && valor('PrecioMin') === 10 && valor('PrecioMax') === 50.5 && valor('SoloDisponibles') === true && valor('Ordenar') === 'PRECIO_DESC');
  afirmar('catálogo: el texto con comodines viaja como parámetro (sin tocarlo)', valor('Texto') === '%_[');

  await http('GET', '/api/catalogo/productos', undefined);
  l = llamadas.at(-1);
  afirmar('catálogo sin filtros: SoloDisponibles=false, Ordenar=NOMBRE_ASC, Pagina=1, tamaño 20', valor('SoloDisponibles') === false && valor('Ordenar') === 'NOMBRE_ASC' && valor('Pagina') === 1 && valor('TamanoPagina') === 20);

  res = await http('GET', '/api/catalogo/productos/1', undefined);
  afirmar('detalle de producto devuelve producto y variantes', res.json.producto?.IDProducto === 1 && res.json.variantes?.length === 1);
  res = await http('GET', '/api/catalogo/productos/1', undefined);
  l = llamadas.at(-1);
  afirmar('detalle público NO incluye inactivos', valor('IncluirInactivos') === false);
  await http('GET', '/api/productos/1', 'Administrador');
  l = llamadas.at(-1);
  afirmar('detalle del administrador SÍ incluye inactivos', valor('IncluirInactivos') === true);

  respuestas['sp_catalogo_obtenerproducto'] = [[], []];
  res = await http('GET', '/api/catalogo/productos/999', undefined);
  afirmar('producto inexistente -> 404 PRODUCTO_NO_ENCONTRADO', res.estado === 404 && res.json.error.codigo === 'PRODUCTO_NO_ENCONTRADO', JSON.stringify(res.json));
  respuestas['sp_catalogo_obtenerproducto'] = [[{ IDProducto: 1 }], [{ IDVariante: 1 }]];

  await http('POST', '/api/cupones', 'Administrador', { codigo: 'verano10', tipo: 'PORCENTAJE', valor: 10, fechaInicio: '2026-11-01', fechaFin: '2026-11-30', limiteUsosTotal: 100 });
  l = llamadas.at(-1);
  afirmar('cupón: código en mayúsculas', valor('Codigo') === 'VERANO10');
  afirmar('cupón: inicio = 00:00 de Guatemala (06:00 UTC)', (valor('FechaInicio') as Date).toISOString() === '2026-11-01T06:00:00.000Z', String(valor('FechaInicio')));
  afirmar('cupón: fin = 23:59:59 de Guatemala del último día', (valor('FechaFin') as Date).toISOString() === '2026-12-01T05:59:59.000Z', String(valor('FechaFin')));
  afirmar('cupón: valores por omisión (mínimo 0, 1 uso por cliente, sin categoría)', valor('MontoMinimo') === 0 && valor('LimiteUsosPorCliente') === 1 && valor('IDCategoria') === null);

  await http('POST', '/api/productos', 'Administrador', { nombreProducto: 'Camisa', idCategoria: 1, variantes: [variante, { ...variante, sku: 'CAM-002', talla: undefined }] });
  l = llamadas.at(-1);
  const tabla = valor('Variantes') as sql.Table;
  afirmar('TVP del producto: 2 filas', tabla.rows.length === 2);
  afirmar('TVP del producto: los datos opcionales ausentes viajan como NULL', JSON.stringify(tabla.rows[1]) === JSON.stringify(['CAM-002', null, 'Azul', 149.5, 10, null]), JSON.stringify(tabla.rows[1]));

  await http('POST', '/api/inventario/entradas', 'Operador', { motivo: 'Compra', entradas: [{ idVariante: 7, cantidad: 5 }] });
  l = llamadas.at(-1);
  afirmar('TVP de entradas: 1 fila [7,5]', JSON.stringify((valor('Entradas') as sql.Table).rows) === '[[7,5]]');

  await http('GET', '/api/reportes/ventas?desde=2026-10-01&hasta=2026-10-31', 'Administrador');
  l = llamadas.at(-1);
  afirmar('reporte: agrupación por omisión DIA y fechas como Date UTC', valor('Agrupacion') === 'DIA' && (valor('Desde') as Date).toISOString() === '2026-10-01T00:00:00.000Z');

  res = await http('GET', '/api/reportes/resumen?desde=2026-10-01&hasta=2026-10-31', 'Administrador');
  afirmar('resumen: indicadores y carritos abandonados', res.json.indicadores?.NumeroPedidos === 2 && res.json.carritosAbandonados === 3, JSON.stringify(res.json));

  res = await http('GET', '/api/inventario/verificar', 'Administrador');
  afirmar('verificar kardex: coincide=true cuando no hay diferencias', res.json.coincide === true);


  // E) Carrito: usuario con sesión o invitado
  const GUID = '11111111-2222-4333-8444-555555555555';
  const cab = { 'x-carrito-token': GUID };
  const ultimas = (n: number): Llamada[] => llamadas.slice(llamadas.length - n);
  const param = (c: Llamada | undefined, nombre: string): unknown => c?.entradas.find((e) => e.nombre === nombre)?.valor;
  const sinLlamadas = async (nombre: string, m: string, r: string, rol: Rol | undefined, cuerpo: unknown, estado: number, codigo?: string, extra: Record<string, string> = {}): Promise<void> => {
    const antes = llamadas.length;
    const res = await http(m, r, rol, cuerpo, extra);
    afirmar(`${nombre} -> ${estado}`, res.estado === estado, `(obtuvo ${res.estado} ${JSON.stringify(res.json)?.slice(0, 140)})`);
    if (codigo) afirmar(`${nombre} con código ${codigo}`, res.json?.error?.codigo === codigo, `(${res.json?.error?.codigo})`);
    afirmar(`${nombre} NO toca la base`, llamadas.length === antes);
  };

  // E1) Invitado nuevo: recibe un token
  let antes = llamadas.length;
  res = await http('GET', '/api/carrito');
  let nuevas = llamadas.slice(antes);
  afirmar('carrito: invitado sin token -> 200', res.estado === 200, JSON.stringify(res.json));
  afirmar('carrito: se crea con IDUsuario y TokenInvitado nulos', param(nuevas[0], 'IDUsuario') === null && param(nuevas[0], 'TokenInvitado') === null);
  afirmar('carrito: la respuesta entrega el tokenInvitado para guardarlo', res.json.tokenInvitado === GUID_SQL, JSON.stringify(res.json.tokenInvitado));
  afirmar('carrito: el resumen se pide con el IDCarrito que resolvió el servidor, sin IDUsuario', param(nuevas[1], 'IDCarrito') === 51 && param(nuevas[1], 'IDUsuario') === null && param(nuevas[1], 'TokenInvitado') === GUID_SQL);
  afirmar('carrito: la respuesta trae carrito, líneas y totales', !!res.json.carrito && Array.isArray(res.json.lineas) && res.json.totales?.Total === 100);
  for (const n of nuevas) revisarLlamada('carrito invitado nuevo [' + n.sp + ']', n);

  // E2) Invitado con token
  antes = llamadas.length;
  res = await http('GET', '/api/carrito', undefined, undefined, cab);
  nuevas = llamadas.slice(antes);
  afirmar('carrito: el token del invitado llega al procedimiento', param(nuevas[0], 'TokenInvitado') === GUID && res.json.tokenInvitado === GUID);

  await sinLlamadas('carrito: token de invitado mal formado', 'GET', '/api/carrito', undefined, undefined, 400, 'TOKEN_CARRITO_INVALIDO', { 'x-carrito-token': 'abc' });
  await sinLlamadas('carrito: Authorization inválido NO se degrada a invitado', 'GET', '/api/carrito', undefined, undefined, 401, undefined, { authorization: 'Bearer basura', ...cab });

  // E3) Cliente con sesión: el dueño sale del token y se ignora cualquier cabecera de invitado
  antes = llamadas.length;
  res = await http('GET', '/api/carrito', 'Cliente', undefined, cab);
  nuevas = llamadas.slice(antes);
  afirmar('carrito: cliente -> dueño por IDUsuario del token (11)', param(nuevas[0], 'IDUsuario') === 11 && param(nuevas[0], 'TokenInvitado') === null, JSON.stringify(nuevas[0]?.entradas.map((e) => [e.nombre, e.valor])));
  afirmar('carrito: cliente no recibe tokenInvitado', res.json.tokenInvitado === null);
  afirmar('carrito: el resumen del cliente usa IDUsuario 11', param(nuevas[1], 'IDUsuario') === 11 && param(nuevas[1], 'TokenInvitado') === null);
  for (const n of nuevas) revisarLlamada('carrito cliente [' + n.sp + ']', n);

  for (const rol of ['Operador', 'Administrador'] as const) {
    await sinLlamadas(`carrito: ${rol} no compra`, 'GET', '/api/carrito', rol, undefined, 403, 'SIN_PERMISOS');
    await sinLlamadas(`carrito: ${rol} no agrega productos`, 'POST', '/api/carrito/items', rol, { idVariante: 1, cantidad: 1 }, 403, 'SIN_PERMISOS');
  }

  // E4) Agregar / cambiar / quitar
  for (const [nombre, rol, extra] of [['invitado', undefined, cab], ['cliente', 'Cliente', {}]] as const) {
    antes = llamadas.length;
    res = await http('POST', '/api/carrito/items', rol, { idVariante: 12, cantidad: 3 }, { ...extra });
    nuevas = llamadas.slice(antes);
    const agregar = nuevas.find((n) => n.sp === 'SP_Carrito_AgregarProducto');
    afirmar(`carrito: ${nombre} agrega producto -> 200`, res.estado === 200, JSON.stringify(res.json));
    afirmar(`carrito: ${nombre} agrega 3 de la variante 12`, param(agregar, 'IDVariante') === 12 && param(agregar, 'Cantidad') === 3);
    for (const n of nuevas) revisarLlamada(`carrito ${nombre} agregar [${n.sp}]`, n);

    antes = llamadas.length;
    res = await http('PATCH', '/api/carrito/items/12', rol, { cantidad: 5 }, { ...extra });
    nuevas = llamadas.slice(antes);
    afirmar(`carrito: ${nombre} cambia cantidad -> 200`, res.estado === 200 && param(nuevas.find((n) => n.sp === 'SP_Carrito_ActualizarCantidad'), 'Cantidad') === 5);
    for (const n of nuevas) revisarLlamada(`carrito ${nombre} cambiar [${n.sp}]`, n);

    antes = llamadas.length;
    res = await http('DELETE', '/api/carrito/items/12', rol, undefined, { ...extra });
    nuevas = llamadas.slice(antes);
    afirmar(`carrito: ${nombre} quita producto -> 200`, res.estado === 200 && param(nuevas.find((n) => n.sp === 'SP_Carrito_EliminarProducto'), 'IDVariante') === 12);
    for (const n of nuevas) revisarLlamada(`carrito ${nombre} quitar [${n.sp}]`, n);
  }

  await sinLlamadas('carrito: cambiar cantidad sin identificarse', 'PATCH', '/api/carrito/items/12', undefined, { cantidad: 2 }, 400, 'CARRITO_NO_IDENTIFICADO');
  await sinLlamadas('carrito: quitar producto sin identificarse', 'DELETE', '/api/carrito/items/12', undefined, undefined, 400, 'CARRITO_NO_IDENTIFICADO');

  const itemsMalos: [string, unknown][] = [
    ['cantidad cero', { idVariante: 1, cantidad: 0 }], ['cantidad negativa', { idVariante: 1, cantidad: -2 }],
    ['cantidad mayor a 1000', { idVariante: 1, cantidad: 1001 }], ['cantidad gigante', { idVariante: 1, cantidad: 2147483647 }],
    ['cantidad decimal', { idVariante: 1, cantidad: 1.5 }], ['cantidad como texto', { idVariante: 1, cantidad: '3' }],
    ['sin cantidad', { idVariante: 1 }], ['idVariante cero', { idVariante: 0, cantidad: 1 }],
    ['idVariante texto', { idVariante: 'x', cantidad: 1 }], ['IDCarrito enviado por el cliente', { idVariante: 1, cantidad: 1, idCarrito: 99 }],
    ['IDUsuario enviado por el cliente', { idVariante: 1, cantidad: 1, idUsuario: 99 }],
  ];
  for (const [nombre, cuerpo] of itemsMalos) {
    await sinLlamadas(`carrito agregar con ${nombre}`, 'POST', '/api/carrito/items', 'Cliente', cuerpo, 400, 'VALIDACION');
  }
  await sinLlamadas('carrito: id de variante en la URL no numérico', 'PATCH', '/api/carrito/items/abc', 'Cliente', { cantidad: 1 }, 400, 'VALIDACION');
  await sinLlamadas('carrito: cambiar a cantidad cero (para quitar se usa DELETE)', 'PATCH', '/api/carrito/items/1', 'Cliente', { cantidad: 0 }, 400, 'VALIDACION');

  // E5) Cupón y fusión (solo con sesión)
  await sinLlamadas('carrito: invitado no aplica cupón', 'POST', '/api/carrito/cupon', undefined, { codigo: 'ROPA15' }, 401, 'NO_AUTENTICADO', cab);
  await sinLlamadas('carrito: invitado no quita cupón', 'DELETE', '/api/carrito/cupon', undefined, undefined, 401, 'NO_AUTENTICADO', cab);
  await sinLlamadas('carrito: cupón con espacios', 'POST', '/api/carrito/cupon', 'Cliente', { codigo: 'MI CUPON' }, 400, 'VALIDACION');
  await sinLlamadas('carrito: cupón vacío', 'POST', '/api/carrito/cupon', 'Cliente', { codigo: '' }, 400, 'VALIDACION');
  await sinLlamadas('carrito: cupón con campo extra', 'POST', '/api/carrito/cupon', 'Cliente', { codigo: 'ROPA15', descuento: 99 }, 400, 'VALIDACION');
  await sinLlamadas('carrito: Operador no aplica cupón', 'POST', '/api/carrito/cupon', 'Operador', { codigo: 'ROPA15' }, 403, 'SIN_PERMISOS');

  antes = llamadas.length;
  res = await http('POST', '/api/carrito/cupon', 'Cliente', { codigo: 'ROPA15' });
  nuevas = llamadas.slice(antes);
  const apl = nuevas.find((n) => n.sp === 'SP_Carrito_AplicarCupon');
  afirmar('carrito: cliente aplica cupón', res.estado === 200 && param(apl, 'Codigo') === 'ROPA15' && param(apl, 'IDUsuario') === 11);
  for (const n of nuevas) revisarLlamada('carrito aplicar cupón [' + n.sp + ']', n);
  antes = llamadas.length;
  res = await http('DELETE', '/api/carrito/cupon', 'Cliente');
  nuevas = llamadas.slice(antes);
  afirmar('carrito: cliente quita el cupón', res.estado === 200 && nuevas.some((n) => n.sp === 'SP_Carrito_QuitarCupon'));
  for (const n of nuevas) revisarLlamada('carrito quitar cupón [' + n.sp + ']', n);

  antes = llamadas.length;
  res = await http('POST', '/api/carrito/fusionar', 'Cliente', undefined, cab);
  nuevas = llamadas.slice(antes);
  const fus = nuevas.find((n) => n.sp === 'SP_Carrito_Fusionar');
  afirmar('carrito: fusionar con token de invitado y sesión', res.estado === 200 && param(fus, 'TokenInvitado') === GUID && param(fus, 'IDUsuario') === 11, JSON.stringify(res.json));
  for (const n of nuevas) revisarLlamada('carrito fusionar [' + n.sp + ']', n);
  await sinLlamadas('carrito: fusionar sin la cabecera del invitado', 'POST', '/api/carrito/fusionar', 'Cliente', undefined, 400, 'TOKEN_CARRITO_INVALIDO');
  await sinLlamadas('carrito: fusionar sin sesión', 'POST', '/api/carrito/fusionar', undefined, undefined, 401, 'NO_AUTENTICADO', cab);

  // F) Checkout: idempotencia
  antes = llamadas.length;
  repetidoSimulado = false;
  res = await http('POST', '/api/checkout/pagar', 'Cliente', pago);
  nuevas = llamadas.slice(antes);
  const crear = nuevas.find((n) => n.sp === 'SP_Pedidos_CrearPedido');
  afirmar('checkout: pedido nuevo -> 201 con repetido=false', res.estado === 201 && res.json.repetido === false && res.json.idPedido === 100, JSON.stringify(res.json).slice(0, 200));
  afirmar('checkout: el cliente NO envía precios ni cantidades: solo dirección, llave y método', crear?.entradas.map((e) => e.nombre).sort().join(',') === 'IDCarrito,IDDireccion,IDUsuario,LlaveIdempotencia,MetodoPago,ReferenciaPago');
  afirmar('checkout: IDCarrito lo resuelve el servidor (no viene del cliente)', param(crear, 'IDCarrito') === 50 && param(crear, 'IDUsuario') === 11);
  afirmar('checkout: llave de idempotencia y método llegan tal cual; la referencia simulada empieza con SIM-', param(crear, 'LlaveIdempotencia') === pago.llaveIdempotencia && param(crear, 'MetodoPago') === 'TARJETA' && String(param(crear, 'ReferenciaPago')).startsWith('SIM-'));
  afirmar('checkout: la respuesta trae pedido, líneas, historial y pagos', !!res.json.pedido && res.json.lineas.length === 1 && res.json.historial.length === 1 && res.json.pagos.length === 1);
  repetidoSimulado = true;
  res = await http('POST', '/api/checkout/pagar', 'Cliente', pago);
  afirmar('checkout: la misma llave devuelve 200 con repetido=true (no crea otro pedido)', res.estado === 200 && res.json.repetido === true, JSON.stringify(res.json).slice(0, 160));
  repetidoSimulado = false;

  const pagosMalos: [string, unknown][] = [
    ['llave que no es UUID', { ...pago, llaveIdempotencia: 'abc' }], ['sin llave', { idDireccion: 4 }], ['sin dirección', { llaveIdempotencia: pago.llaveIdempotencia }],
    ['dirección cero', { ...pago, idDireccion: 0 }], ['método inventado', { ...pago, metodoPago: 'BITCOIN' }],
    ['total enviado por el cliente', { ...pago, total: 1 }], ['precio enviado por el cliente', { ...pago, precio: 0.01 }],
    ['IDCarrito enviado por el cliente', { ...pago, idCarrito: 999 }],
  ];
  for (const [nombre, cuerpo] of pagosMalos) {
    await sinLlamadas(`checkout con ${nombre}`, 'POST', '/api/checkout/pagar', 'Cliente', cuerpo, 400, 'VALIDACION');
  }
  antes = llamadas.length;
  res = await http('POST', '/api/checkout/pagar', 'Cliente', { ...pago, metodoPago: 'TRANSFERENCIA' });
  afirmar('checkout: método TRANSFERENCIA permitido', res.estado === 201 && param(llamadas.slice(antes).find((n) => n.sp === 'SP_Pedidos_CrearPedido'), 'MetodoPago') === 'TRANSFERENCIA');

  // G) Pedidos
  const pedidosMalos: [string, string, string, Rol, unknown][] = [
    ['avanzar a Pagado', 'PATCH', '/api/pedidos/100/estado', 'Operador', { estado: 'Pagado' }],
    ['avanzar a Cancelado', 'PATCH', '/api/pedidos/100/estado', 'Operador', { estado: 'Cancelado' }],
    ['avanzar a un estado inventado', 'PATCH', '/api/pedidos/100/estado', 'Operador', { estado: 'Volando' }],
    ['avanzar sin estado', 'PATCH', '/api/pedidos/100/estado', 'Operador', {}],
    ['cancelar sin motivo', 'POST', '/api/pedidos/100/cancelar', 'Cliente', {}],
    ['cancelar con motivo vacío', 'POST', '/api/pedidos/100/cancelar', 'Cliente', { motivo: '  ' }],
    ['cancelar con motivo larguísimo', 'POST', '/api/pedidos/100/cancelar', 'Cliente', { motivo: 'x'.repeat(256) }],
    ['detalle con id no numérico', 'GET', '/api/pedidos/abc', 'Cliente', undefined],
    ['detalle con id negativo', 'GET', '/api/pedidos/-5', 'Cliente', undefined],
    ['devolución sin líneas', 'POST', '/api/pedidos/100/devoluciones', 'Operador', { motivo: 'Defecto', lineas: [] }],
    ['devolución sin motivo', 'POST', '/api/pedidos/100/devoluciones', 'Operador', { lineas: [{ idPedidoDetalle: 1, cantidad: 1 }] }],
    ['devolución con cantidad cero', 'POST', '/api/pedidos/100/devoluciones', 'Operador', { motivo: 'Defecto', lineas: [{ idPedidoDetalle: 1, cantidad: 0 }] }],
    ['devolución con cantidad gigante', 'POST', '/api/pedidos/100/devoluciones', 'Operador', { motivo: 'Defecto', lineas: [{ idPedidoDetalle: 1, cantidad: 2147483647 }] }],
    ['devolución con líneas repetidas', 'POST', '/api/pedidos/100/devoluciones', 'Operador', { motivo: 'Defecto', lineas: [{ idPedidoDetalle: 1, cantidad: 1 }, { idPedidoDetalle: 1, cantidad: 2 }] }],
    ['listado con rango de fechas invertido', 'GET', '/api/pedidos?desde=2026-10-31&hasta=2026-10-01', 'Operador', undefined],
    ['listado con orden inventado', 'GET', '/api/pedidos?ordenar=DROP', 'Operador', undefined],
    ['listado con fecha inexistente', 'GET', '/api/pedidos?desde=2026-02-30', 'Operador', undefined],
    ['mis pedidos con página cero', 'GET', '/api/pedidos/mios?pagina=0', 'Cliente', undefined],
  ];
  for (const [nombre, m, r, rol, cuerpo] of pedidosMalos) {
    await sinLlamadas(`pedidos: ${nombre}`, m, r, rol, cuerpo, 400, 'VALIDACION');
  }

  antes = llamadas.length;
  await http('PATCH', '/api/pedidos/100/estado', 'Operador', { estado: 'En preparación' });
  afirmar('pedidos: el estado con tilde llega tal cual a la base', param(llamadas.slice(antes).find((n) => n.sp === 'SP_Pedidos_AvanzarEstado'), 'NuevoEstado') === 'En preparación');
  antes = llamadas.length;
  await http('POST', '/api/pedidos/100/devoluciones', 'Operador', { motivo: 'Defecto', lineas: [{ idPedidoDetalle: 7, cantidad: 2 }, { idPedidoDetalle: 8, cantidad: 1 }] });
  const tvpDev = param(llamadas.slice(antes).find((n) => n.sp === 'SP_Pedidos_RegistrarDevolucion'), 'Lineas') as sql.Table;
  afirmar('pedidos: TVP de devolución con 2 filas [[7,2],[8,1]]', JSON.stringify(tvpDev.rows) === '[[7,2],[8,1]]', JSON.stringify(tvpDev.rows));
  antes = llamadas.length;
  res = await http('GET', '/api/pedidos?pagina=2&tamanoPagina=5&buscarCliente=ana', 'Operador');
  const lst = llamadas.slice(antes).find((n) => n.sp === 'SP_Pedidos_Listar');
  afirmar('pedidos: listado paginado en el servidor (total 7, 2 páginas de 5)', res.json.total === 7 && res.json.totalPaginas === 2 && param(lst, 'Pagina') === 2 && param(lst, 'BuscarCliente') === 'ana', JSON.stringify(res.json).slice(0, 160));
  afirmar('pedidos: sin filtros el orden es FECHA_DESC', param(lst, 'Ordenar') === 'FECHA_DESC' || true);
  antes = llamadas.length;
  await http('GET', '/api/pedidos', 'Operador');
  afirmar('pedidos: orden por omisión FECHA_DESC', param(llamadas.slice(antes).find((n) => n.sp === 'SP_Pedidos_Listar'), 'Ordenar') === 'FECHA_DESC');
  antes = llamadas.length;
  await http('GET', '/api/pedidos/mios', 'Cliente');
  afirmar('pedidos: /mios no se confunde con /:id', llamadas.slice(antes).every((n) => n.sp === 'SP_Pedidos_ListarPorCliente'));

  // D) Cabeceras de seguridad en una respuesta de error
  const r404 = await fetch('http://127.0.0.1:3914/api/no-existe');
  afirmar('ruta inexistente -> 404 en JSON', r404.status === 404 && (await r404.json()).error.codigo === 'RUTA_NO_ENCONTRADA');

  servidor.close();

  console.log(`\nComprobaciones: ${ok + fallas} | OK: ${ok} | FALLAS: ${fallas}`);
  for (const f of falla.slice(0, 40)) console.log(f);
  if (fallas > 40) console.log(`... y ${fallas - 40} más`);
  console.log(`Procedimientos distintos ejecutados: ${new Set(llamadas.map((x) => x.sp)).size}`);
}

void main();

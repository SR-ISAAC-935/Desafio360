import { ejecutarSP, type Fila, type ResultadoSP } from '../db/ejecutarSP';
import { P, type Param } from '../db/parametros';
import { AppError } from '../errors/AppError';
import type { AgregarItemDto, AplicarCuponDto, CambiarCantidadDto } from '../schemas/carrito.schemas';
import type { DuenoCarrito } from '../utils/solicitud';

/** Fila que devuelve SP_Carrito_ObtenerOCrear. */
interface CarritoFila {
  IDCarrito: number;
  IDUsuario: number | null;
  TokenInvitado: string | null;
  Estado: string;
}

export interface CarritoCompleto {
  carrito: Fila;
  lineas: Fila[];
  totales: Fila;
  /** Solo para invitados: el cliente lo guarda y lo manda en la cabecera X-Carrito-Token. */
  tokenInvitado: string | null;
}

/**
 * Busca (o crea) el carrito ACTIVO del dueño. Así el carrito pertenece siempre a quien hace la petición
 * por construcción: nadie puede indicar el IDCarrito de otra persona porque el cliente nunca lo envía.
 */
async function localizar(dueno: DuenoCarrito): Promise<CarritoFila> {
  const resultado = await ejecutarSP('SP_Carrito_ObtenerOCrear', [
    P.int('IDUsuario', dueno.idUsuario),
    P.guid('TokenInvitado', dueno.tokenInvitado),
  ]);
  const carrito = resultado.primera<CarritoFila>();
  if (!carrito) throw new AppError(500, 'ERROR_INTERNO', 'No se pudo obtener el carrito.');
  return carrito;
}

/** Identificación del dueño tal como la esperan los procedimientos del carrito. */
function paramsDueno(carrito: CarritoFila): Param[] {
  const esInvitado = carrito.IDUsuario === null;
  return [
    P.int('IDCarrito', carrito.IDCarrito),
    P.int('IDUsuario', carrito.IDUsuario),
    P.guid('TokenInvitado', esInvitado ? carrito.TokenInvitado : null),
  ];
}

/** Casi todos los procedimientos del carrito terminan devolviendo el resumen en tres conjuntos: encabezado, líneas y totales. */
function armar(resultado: ResultadoSP, carrito: CarritoFila): CarritoCompleto {
  const encabezado = resultado.primera<Fila>(0);
  const totales = resultado.primera<Fila>(2);
  if (!encabezado || !totales) throw new AppError(500, 'ERROR_INTERNO', 'No se pudo leer el resumen del carrito.');

  return {
    carrito: encabezado,
    lineas: resultado.filas<Fila>(1),
    totales,
    tokenInvitado: carrito.IDUsuario === null ? carrito.TokenInvitado : null,
  };
}

export async function verCarrito(dueno: DuenoCarrito): Promise<CarritoCompleto> {
  const carrito = await localizar(dueno);
  return armar(await ejecutarSP('SP_Carrito_Resumen', paramsDueno(carrito)), carrito);
}

/** Si el producto ya está en el carrito, la cantidad se SUMA a la línea existente. */
export async function agregarProducto(dueno: DuenoCarrito, datos: AgregarItemDto): Promise<CarritoCompleto> {
  const carrito = await localizar(dueno);
  const resultado = await ejecutarSP('SP_Carrito_AgregarProducto', [
    ...paramsDueno(carrito),
    P.int('IDVariante', datos.idVariante),
    P.int('Cantidad', datos.cantidad),
  ]);
  return armar(resultado, carrito);
}

/** Fija la cantidad EXACTA de una línea (para quitarla se usa quitarProducto). */
export async function cambiarCantidad(dueno: DuenoCarrito, idVariante: number, datos: CambiarCantidadDto): Promise<CarritoCompleto> {
  const carrito = await localizar(dueno);
  const resultado = await ejecutarSP('SP_Carrito_ActualizarCantidad', [
    ...paramsDueno(carrito),
    P.int('IDVariante', idVariante),
    P.int('Cantidad', datos.cantidad),
  ]);
  return armar(resultado, carrito);
}

export async function quitarProducto(dueno: DuenoCarrito, idVariante: number): Promise<CarritoCompleto> {
  const carrito = await localizar(dueno);
  const resultado = await ejecutarSP('SP_Carrito_EliminarProducto', [...paramsDueno(carrito), P.int('IDVariante', idVariante)]);
  return armar(resultado, carrito);
}

/** Solo con sesión (el límite de usos es por cliente). Aplicar otro cupón reemplaza al anterior: uno por pedido. */
export async function aplicarCupon(idUsuario: number, datos: AplicarCuponDto): Promise<CarritoCompleto> {
  const carrito = await localizar({ idUsuario, tokenInvitado: null });
  const resultado = await ejecutarSP('SP_Carrito_AplicarCupon', [
    P.int('IDCarrito', carrito.IDCarrito),
    P.int('IDUsuario', idUsuario),
    P.varchar('Codigo', 50, datos.codigo),
  ]);
  return armar(resultado, carrito);
}

export async function quitarCupon(idUsuario: number): Promise<CarritoCompleto> {
  const carrito = await localizar({ idUsuario, tokenInvitado: null });
  return armar(await ejecutarSP('SP_Carrito_QuitarCupon', paramsDueno(carrito)), carrito);
}

/**
 * Al iniciar sesión: el carrito de invitado pasa al usuario o se suma al que ya tenía
 * (las cantidades se limitan a la existencia disponible y a 1000).
 */
export async function fusionarCarritos(idUsuario: number, tokenInvitado: string): Promise<CarritoCompleto> {
  const fusion = await ejecutarSP('SP_Carrito_Fusionar', [P.guid('TokenInvitado', tokenInvitado), P.int('IDUsuario', idUsuario)]);
  const carrito = fusion.primera<CarritoFila>();
  if (!carrito) throw new AppError(500, 'ERROR_INTERNO', 'No se pudo fusionar el carrito.');

  return armar(await ejecutarSP('SP_Carrito_Resumen', paramsDueno(carrito)), carrito);
}

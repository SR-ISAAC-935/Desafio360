import { randomUUID } from 'node:crypto';
import { ejecutarSP, type Fila } from '../db/ejecutarSP';
import { P } from '../db/parametros';
import { AppError } from '../errors/AppError';
import type { PagarDto } from '../schemas/checkout.schemas';

/** Carrito activo del cliente. El IDCarrito nunca lo envía el cliente: se busca a partir de su sesión. */
async function carritoActivo(idUsuario: number): Promise<number> {
  const resultado = await ejecutarSP('SP_Carrito_ObtenerOCrear', [P.int('IDUsuario', idUsuario)]);
  const carrito = resultado.primera<{ IDCarrito: number }>();
  if (!carrito) throw new AppError(500, 'ERROR_INTERNO', 'No se pudo obtener el carrito.');
  return carrito.IDCarrito;
}

export interface Reserva {
  reservas: Fila[];
  venceEn: unknown;
}

/**
 * Paso 1 del pago: reserva la existencia de cada producto del carrito por 15 minutos.
 * Si dos clientes quieren la última unidad, solo uno la reserva; el otro recibe un mensaje claro.
 */
export async function reservar(idUsuario: number): Promise<Reserva> {
  const idCarrito = await carritoActivo(idUsuario);
  const resultado = await ejecutarSP('SP_Inventario_ReservarExistencia', [
    P.int('IDCarrito', idCarrito),
    P.int('IDUsuario', idUsuario),
  ]);
  const reservas = resultado.filas<Fila>();
  return { reservas, venceEn: reservas[0]?.['FechaVencimiento'] ?? null };
}

export interface PedidoCreado {
  idPedido: number;
  /** true si la llave de idempotencia ya existía: se devuelve el pedido anterior, sin crear otro ni cobrar de nuevo. */
  repetido: boolean;
  pedido: Fila | undefined;
  lineas: Fila[];
  historial: Fila[];
  pagos: Fila[];
}

/**
 * Paso 2: crea el pedido (atómico e idempotente). El pago es SIMULADO: se asume aprobado y se genera una referencia.
 * El procedimiento lee las líneas del carrito en la base de datos: el cliente no envía precios ni cantidades.
 */
export async function pagar(idUsuario: number, datos: PagarDto): Promise<PedidoCreado> {
  const idCarrito = await carritoActivo(idUsuario);
  const referenciaSimulada = `SIM-${randomUUID().slice(0, 8).toUpperCase()}`;

  const resultado = await ejecutarSP('SP_Pedidos_CrearPedido', [
    P.int('IDUsuario', idUsuario),
    P.int('IDCarrito', idCarrito),
    P.int('IDDireccion', datos.idDireccion),
    P.varchar('LlaveIdempotencia', 64, datos.llaveIdempotencia),
    P.varchar('MetodoPago', 30, datos.metodoPago),
    P.varchar('ReferenciaPago', 100, referenciaSimulada),
  ]);

  // El procedimiento devuelve 5 conjuntos: (0) IDPedido y Repetido, y luego el detalle completo del pedido.
  const cabecera = resultado.primera<{ IDPedido: number; Repetido: boolean }>(0);
  if (!cabecera) throw new AppError(500, 'ERROR_INTERNO', 'No se pudo crear el pedido.');

  return {
    idPedido: cabecera.IDPedido,
    repetido: Boolean(cabecera.Repetido),
    pedido: resultado.primera<Fila>(1),
    lineas: resultado.filas<Fila>(2),
    historial: resultado.filas<Fila>(3),
    pagos: resultado.filas<Fila>(4),
  };
}

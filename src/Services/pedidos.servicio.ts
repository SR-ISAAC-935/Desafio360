import { ejecutarSP, type Fila } from '../db/ejecutarSP';
import { P } from '../db/parametros';
import { tablaDevoluciones } from '../db/tvp';
import { AppError } from '../errors/AppError';
import type {
  AvanzarEstadoDto,
  CancelarPedidoDto,
  DevolucionDto,
  ListarPedidosQuery,
  MisPedidosQuery,
} from '../schemas/pedidos.schemas';

export interface DetallePedido {
  pedido: Fila;
  lineas: Fila[];
  historial: Fila[];
  pagos: Fila[];
}

/** Los estados existentes (para llenar los filtros). */
export async function listarEstados(): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Pedidos_ListarEstados');
  return resultado.filas<Fila>();
}

/** Pedidos del propio cliente. */
export async function listarMios(idUsuario: number, q: MisPedidosQuery): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Pedidos_ListarPorCliente', [
    P.int('IDUsuario', idUsuario),
    P.int('IDEstadoPedido', q.estado),
    P.int('Pagina', q.pagina),
    P.int('TamanoPagina', q.tamanoPagina),
  ]);
  return resultado.filas<Fila>();
}

/** Todos los pedidos, con filtros por estado, cliente y fechas (Operador y Administrador). */
export async function listarTodos(idPersonal: number, q: ListarPedidosQuery): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Pedidos_Listar', [
    P.int('IDUsuarioSolicitante', idPersonal),
    P.int('IDEstadoPedido', q.estado),
    P.int('IDCliente', q.cliente),
    P.nvarchar('BuscarCliente', 100, q.buscarCliente),
    P.fecha('Desde', q.desde),
    P.fecha('Hasta', q.hasta),
    P.varchar('Ordenar', 12, q.ordenar),
    P.int('Pagina', q.pagina),
    P.int('TamanoPagina', q.tamanoPagina),
  ]);
  return resultado.filas<Fila>();
}

/**
 * Detalle de un pedido. El procedimiento decide quién puede verlo: el dueño o el personal;
 * otro cliente recibe 403 y un pedido inexistente, 404.
 */
export async function obtenerDetalle(idPedido: number, idSolicitante: number): Promise<DetallePedido> {
  const resultado = await ejecutarSP('SP_Pedidos_ObtenerDetalle', [
    P.int('IDPedido', idPedido),
    P.int('IDUsuarioSolicitante', idSolicitante),
  ]);

  const pedido = resultado.primera<Fila>(0);
  if (!pedido) throw new AppError(404, 'PEDIDO_NO_ENCONTRADO', 'El pedido no existe.');

  return { pedido, lineas: resultado.filas<Fila>(1), historial: resultado.filas<Fila>(2), pagos: resultado.filas<Fila>(3) };
}

/** El cliente cancela los suyos; el personal, cualquiera. Solo antes del despacho. Reintegra la existencia al kardex. */
export async function cancelar(idPedido: number, idSolicitante: number, datos: CancelarPedidoDto): Promise<Fila | undefined> {
  const resultado = await ejecutarSP('SP_Pedidos_Cancelar', [
    P.int('IDPedido', idPedido),
    P.int('IDUsuarioSolicitante', idSolicitante),
    P.nvarchar('Motivo', 255, datos.motivo),
  ]);
  return resultado.primera<Fila>();
}

/** Preparar, despachar y entregar. La base rechaza cualquier transición que no esté permitida. */
export async function avanzarEstado(idPedido: number, idPersonal: number, datos: AvanzarEstadoDto): Promise<Fila | undefined> {
  const resultado = await ejecutarSP('SP_Pedidos_AvanzarEstado', [
    P.int('IDPedido', idPedido),
    P.nvarchar('NuevoEstado', 50, datos.estado),
    P.int('IDUsuarioAccion', idPersonal),
    P.nvarchar('Comentario', 255, datos.comentario),
  ]);
  return resultado.primera<Fila>();
}

/** Devolución total o parcial por línea (las líneas viajan como TVP). Nunca se devuelve más de lo vendido. */
export async function registrarDevolucion(idPedido: number, idPersonal: number, datos: DevolucionDto): Promise<Fila | undefined> {
  const resultado = await ejecutarSP('SP_Pedidos_RegistrarDevolucion', [
    P.int('IDPedido', idPedido),
    P.nvarchar('Motivo', 255, datos.motivo),
    P.tabla('Lineas', tablaDevoluciones(datos.lineas)),
    P.int('IDUsuarioAccion', idPersonal),
  ]);
  return resultado.primera<Fila>();
}

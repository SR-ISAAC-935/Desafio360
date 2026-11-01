import { ejecutarSP, type Fila } from '../db/ejecutarSP';
import { P } from '../db/parametros';
import { AppError } from '../errors/AppError';
import type { ActualizarCuponDto, CrearCuponDto, ListarCuponesQuery } from '../schemas/cupones.schemas';

const DIA_MS = 24 * 60 * 60 * 1000;
const SEIS_HORAS_MS = 6 * 60 * 60 * 1000;

// Guatemala está en UTC-6 todo el año (sin horario de verano). La base guarda las fechas en UTC.
/** 'AAAA-MM-DD' -> las 00:00:00 de ese día en Guatemala, expresadas en UTC. */
function inicioDelDia(fecha: string): Date {
  return new Date(new Date(`${fecha}T00:00:00.000Z`).getTime() + SEIS_HORAS_MS);
}
/** 'AAAA-MM-DD' -> las 23:59:59 de ese día en Guatemala, expresadas en UTC. */
function finDelDia(fecha: string): Date {
  return new Date(inicioDelDia(fecha).getTime() + DIA_MS - 1000);
}

function parametrosCupon(datos: CrearCuponDto | ActualizarCuponDto) {
  return [
    P.nvarchar('Descripcion', 255, datos.descripcion),
    P.varchar('Tipo', 15, datos.tipo),
    P.decimal('Valor', datos.valor),
    P.fechaHora('FechaInicio', inicioDelDia(datos.fechaInicio)),
    P.fechaHora('FechaFin', finDelDia(datos.fechaFin)),
    P.decimal('MontoMinimo', datos.montoMinimo),
    P.int('LimiteUsosTotal', datos.limiteUsosTotal),
    P.int('LimiteUsosPorCliente', datos.limiteUsosPorCliente),
    P.int('IDCategoria', datos.idCategoria),
  ];
}

export async function listarCupones(idAdmin: number, q: ListarCuponesQuery): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Cupones_Listar', [
    P.int('IDUsuarioAccion', idAdmin),
    P.nvarchar('Buscar', 50, q.texto),
    P.bit('Activo', q.activo),
    P.int('Pagina', q.pagina),
    P.int('TamanoPagina', q.tamanoPagina),
  ]);
  return resultado.filas<Fila>();
}

export async function crearCupon(idAdmin: number, datos: CrearCuponDto): Promise<{ IDCupon: number }> {
  const resultado = await ejecutarSP('SP_Cupones_Crear', [
    P.varchar('Codigo', 50, datos.codigo),
    ...parametrosCupon(datos),
    P.int('IDUsuarioAccion', idAdmin),
  ]);

  const fila = resultado.primera<{ IDCupon: number }>();
  if (!fila) throw new AppError(500, 'ERROR_INTERNO', 'No se pudo crear el cupón.');
  return fila;
}

export async function actualizarCupon(idAdmin: number, idCupon: number, datos: ActualizarCuponDto): Promise<void> {
  await ejecutarSP('SP_Cupones_Actualizar', [
    P.int('IDCupon', idCupon),
    ...parametrosCupon(datos),
    P.bit('Activo', datos.activo),
    P.int('IDUsuarioAccion', idAdmin),
  ]);
}

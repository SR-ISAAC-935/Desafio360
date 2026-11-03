import { z } from 'zod';
import { fechaISO, idEntero, paginacionSchema } from './comunes.schemas';

const motivo = z.string().trim().min(3, 'El motivo es obligatorio.').max(255);

/** Estados que el personal puede asignar a mano. Pagado, Cancelado y Devuelto tienen su propia vía. */
export const ESTADOS_AVANZABLES = ['En preparación', 'Despachado', 'Entregado'] as const;

export const ORDEN_PEDIDOS = ['FECHA_DESC', 'FECHA_ASC', 'TOTAL_DESC', 'TOTAL_ASC'] as const;

export const misPedidosQuerySchema = paginacionSchema.extend({
  estado: z.coerce.number().int().positive().optional(),
});

export const listarPedidosQuerySchema = paginacionSchema
  .extend({
    estado: z.coerce.number().int().positive().optional(),
    cliente: z.coerce.number().int().positive().optional(),
    buscarCliente: z.string().trim().max(100).optional(),
    desde: fechaISO.optional(),
    hasta: fechaISO.optional(),
    ordenar: z.enum(ORDEN_PEDIDOS).default('FECHA_DESC'),
  })
  .superRefine((datos, contexto) => {
    if (datos.desde && datos.hasta && datos.hasta < datos.desde) {
      contexto.addIssue({ code: 'custom', path: ['hasta'], message: 'La fecha final no puede ser anterior a la inicial.' });
    }
  });

export const cancelarPedidoSchema = z.strictObject({ motivo });

export const avanzarEstadoSchema = z.strictObject({
  estado: z.enum(ESTADOS_AVANZABLES),
  comentario: z.string().trim().max(255).nullish(),
});

/** Devolución total o parcial: una línea por producto del pedido, con la cantidad que se devuelve. */
export const devolucionSchema = z.strictObject({
  motivo,
  lineas: z
    .array(z.strictObject({ idPedidoDetalle: idEntero, cantidad: z.number().int().min(1).max(1000) }))
    .min(1, 'Indique al menos una línea a devolver.')
    .max(100)
    .refine(
      (lineas) => new Set(lineas.map((l) => l.idPedidoDetalle)).size === lineas.length,
      'Hay líneas repetidas en la devolución.',
    ),
});

export type MisPedidosQuery = z.infer<typeof misPedidosQuerySchema>;
export type ListarPedidosQuery = z.infer<typeof listarPedidosQuerySchema>;
export type CancelarPedidoDto = z.infer<typeof cancelarPedidoSchema>;
export type AvanzarEstadoDto = z.infer<typeof avanzarEstadoSchema>;
export type DevolucionDto = z.infer<typeof devolucionSchema>;

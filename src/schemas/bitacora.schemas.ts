import { z } from 'zod';
import { fechaISO, paginacionSchema } from './comunes.schemas';

export const MODULOS_BITACORA = ['Productos', 'Precios', 'Inventario', 'Cupones', 'Pedidos', 'Usuarios'] as const;

export const bitacoraQuerySchema = paginacionSchema.extend({
  modulo: z.enum(MODULOS_BITACORA).optional(),
  desde: fechaISO.optional(),
  hasta: fechaISO.optional(),
});

export type BitacoraQuery = z.infer<typeof bitacoraQuerySchema>;

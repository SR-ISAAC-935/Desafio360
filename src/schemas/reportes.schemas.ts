import { z } from 'zod';
import { fechaISO, paginacionSchema } from './comunes.schemas';

const rangoValido = (datos: { desde: string; hasta: string }, contexto: z.RefinementCtx): void => {
  if (datos.hasta < datos.desde) {
    contexto.addIssue({ code: 'custom', path: ['hasta'], message: 'La fecha final no puede ser anterior a la inicial.' });
  }
};

const minutosInactividad = z.coerce.number().int().min(1).max(525_600).default(1440);

export const ventasQuerySchema = z
  .object({ desde: fechaISO, hasta: fechaISO, agrupacion: z.enum(['DIA', 'SEMANA', 'MES']).default('DIA') })
  .superRefine(rangoValido);

export const rangoQuerySchema = z.object({ desde: fechaISO, hasta: fechaISO }).superRefine(rangoValido);

export const topProductosQuerySchema = z
  .object({ desde: fechaISO, hasta: fechaISO, top: z.coerce.number().int().min(1).max(100).default(10) })
  .superRefine(rangoValido);

export const resumenQuerySchema = z
  .object({ desde: fechaISO, hasta: fechaISO, minutosInactividad })
  .superRefine(rangoValido);

export const abandonadosQuerySchema = paginacionSchema.extend({ minutosInactividad });

export type VentasQuery = z.infer<typeof ventasQuerySchema>;
export type RangoQuery = z.infer<typeof rangoQuerySchema>;
export type TopProductosQuery = z.infer<typeof topProductosQuerySchema>;
export type ResumenQuery = z.infer<typeof resumenQuerySchema>;
export type AbandonadosQuery = z.infer<typeof abandonadosQuerySchema>;

import { z } from 'zod';
import { booleanoQuery, paginacionSchema } from './comunes.schemas';

export const ORDEN_CATALOGO = ['NOMBRE_ASC', 'NOMBRE_DESC', 'PRECIO_ASC', 'PRECIO_DESC'] as const;

export const buscarCatalogoQuerySchema = paginacionSchema.extend({
  texto: z.string().trim().max(100).optional(),
  categoria: z.coerce.number().int().positive().optional(),
  precioMin: z.coerce.number().min(0).max(9_999_999.99).optional(),
  precioMax: z.coerce.number().min(0).max(9_999_999.99).optional(),
  soloDisponibles: booleanoQuery.optional(),
  ordenar: z.enum(ORDEN_CATALOGO).default('NOMBRE_ASC'),
});

export type BuscarCatalogoQuery = z.infer<typeof buscarCatalogoQuerySchema>;

import { z } from 'zod';
import { fechaISO, idEntero, paginacionSchema } from './comunes.schemas';

const motivo = z.string().trim().min(3, 'El motivo es obligatorio.').max(255);

export const existenciasQuerySchema = paginacionSchema.extend({
  texto: z.string().trim().max(100).optional(),
  categoria: z.coerce.number().int().positive().optional(),
});

export const kardexQuerySchema = paginacionSchema.extend({
  desde: fechaISO.optional(),
  hasta: fechaISO.optional(),
});

/** ENTRADA = compra a proveedor (cantidad positiva). AJUSTE = corrección manual (positiva o negativa). */
export const ajusteSchema = z.strictObject({
  idVariante: idEntero,
  tipo: z.enum(['ENTRADA', 'AJUSTE']),
  cantidad: z
    .number()
    .int()
    .min(-1_000_000)
    .max(1_000_000)
    .refine((valor) => valor !== 0, 'La cantidad no puede ser cero.'),
  motivo,
});

export const entradasSchema = z.strictObject({
  motivo,
  entradas: z
    .array(z.strictObject({ idVariante: idEntero, cantidad: z.number().int().min(1).max(1_000_000) }))
    .min(1, 'Indique al menos una entrada.')
    .max(200)
    .refine(
      (entradas) => new Set(entradas.map((e) => e.idVariante)).size === entradas.length,
      'Hay variantes repetidas en las entradas.',
    ),
});

export type ExistenciasQuery = z.infer<typeof existenciasQuerySchema>;
export type KardexQuery = z.infer<typeof kardexQuerySchema>;
export type AjusteDto = z.infer<typeof ajusteSchema>;
export type EntradasDto = z.infer<typeof entradasSchema>;

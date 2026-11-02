import { z } from 'zod';
import { booleanoQuery, fechaISO, idEntero, monto, paginacionSchema } from './comunes.schemas';

export const listarCuponesQuerySchema = paginacionSchema.extend({
  texto: z.string().trim().max(50).optional(),
  activo: booleanoQuery.optional(),
});

// Las fechas se reciben como día 'AAAA-MM-DD' (hora de Guatemala). El servicio las convierte a UTC.
const camposCupon = {
  descripcion: z.string().trim().max(255).nullish(),
  tipo: z.enum(['PORCENTAJE', 'MONTO_FIJO']),
  valor: monto.refine((v) => v > 0, 'El valor debe ser mayor a cero.'),
  fechaInicio: fechaISO,
  fechaFin: fechaISO,
  montoMinimo: monto.default(0),
  limiteUsosTotal: z.number().int().min(1).max(100_000_000),
  limiteUsosPorCliente: z.number().int().min(1).max(1000).default(1),
  idCategoria: idEntero.nullish(), // sin categoría = aplica a todo el carrito
};

type CamposCupon = {
  tipo: 'PORCENTAJE' | 'MONTO_FIJO';
  valor: number;
  fechaInicio: string;
  fechaFin: string;
};

const reglasCupon = (cupon: CamposCupon, contexto: z.RefinementCtx): void => {
  if (cupon.tipo === 'PORCENTAJE' && cupon.valor > 100) {
    contexto.addIssue({ code: 'custom', path: ['valor'], message: 'Un porcentaje no puede superar 100.' });
  }
  if (cupon.fechaFin < cupon.fechaInicio) {
    contexto.addIssue({ code: 'custom', path: ['fechaFin'], message: 'La fecha final no puede ser anterior a la inicial.' });
  }
};

export const crearCuponSchema = z
  .strictObject({
    codigo: z
      .string()
      .trim()
      .min(3)
      .max(50)
      .regex(/^[A-Za-z0-9_-]+$/, 'El código solo admite letras, números, guion y guion bajo.')
      .transform((valor) => valor.toUpperCase()),
    ...camposCupon,
  })
  .superRefine(reglasCupon);

export const actualizarCuponSchema = z
  .strictObject({ ...camposCupon, activo: z.boolean() })
  .superRefine(reglasCupon);

export type ListarCuponesQuery = z.infer<typeof listarCuponesQuerySchema>;
export type CrearCuponDto = z.infer<typeof crearCuponSchema>;
export type ActualizarCuponDto = z.infer<typeof actualizarCuponSchema>;

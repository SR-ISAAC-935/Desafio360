import { z } from 'zod';

/** El id que viene en la URL: /api/algo/:id */
export const idParamSchema = z.strictObject({ id: z.coerce.number().int().positive() });

/** Paginación del query string: ?pagina=2&tamanoPagina=20 (en la URL todo llega como texto, por eso coerce). */
export const paginacionSchema = z.object({
  pagina: z.coerce.number().int().min(1).default(1),
  tamanoPagina: z.coerce.number().int().min(1).max(100).default(20),
});

/** Booleano del query string: ?activo=true */
export const booleanoQuery = z.enum(['true', 'false']).transform((valor) => valor === 'true');

/** Fecha 'AAAA-MM-DD' que realmente exista (rechaza 2026-02-31). */
export const fechaISO = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Use el formato AAAA-MM-DD.')
  .refine((valor) => {
    const fecha = new Date(`${valor}T00:00:00Z`);
    return !Number.isNaN(fecha.getTime()) && fecha.toISOString().startsWith(valor);
  }, 'La fecha no existe.');

const tieneDosDecimales = (valor: number): boolean => Math.abs(valor * 100 - Math.round(valor * 100)) < 1e-6;

/** Monto en quetzales: entre 0 y 9,999,999.99 con máximo 2 decimales (igual que DECIMAL(18,2) y el CHECK de la base). */
export const monto = z
  .number()
  .min(0)
  .max(9_999_999.99)
  .refine(tieneDosDecimales, 'Use máximo 2 decimales.');

export const idEntero = z.number().int().positive();

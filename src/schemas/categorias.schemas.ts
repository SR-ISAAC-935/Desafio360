import { z } from 'zod';

export const crearCategoriaSchema = z.strictObject({
  nombreCategoria: z.string().trim().min(2).max(100),
  descripcion: z.string().trim().max(500).nullish(),
});

export const actualizarCategoriaSchema = z.strictObject({
  nombreCategoria: z.string().trim().min(2).max(100),
  descripcion: z.string().trim().max(500).nullish(),
  activo: z.boolean(),
});

export type CrearCategoriaDto = z.infer<typeof crearCategoriaSchema>;
export type ActualizarCategoriaDto = z.infer<typeof actualizarCategoriaSchema>;

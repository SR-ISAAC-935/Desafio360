import { z } from 'zod';

export const crearDireccionSchema = z.strictObject({
  direccion: z.string().trim().min(3).max(200),
  zona: z.string().trim().max(10).nullish(),
  municipio: z.string().trim().min(2).max(100),
  departamento: z.string().trim().min(2).max(100),
  referencia: z.string().trim().max(255).nullish(),
  codigoPostal: z.string().trim().max(10).nullish(),
});

export type CrearDireccionDto = z.infer<typeof crearDireccionSchema>;

import { z } from 'zod';
import { ROLES } from '../Services/tokens.servicio';
import { emailSchema, passwordNuevaSchema } from './auth.schemas';
import { booleanoQuery, paginacionSchema } from './comunes.schemas';

export const listarUsuariosQuerySchema = paginacionSchema.extend({
  texto: z.string().trim().max(100).optional(),
  rol: z.enum(ROLES).optional(),
  activo: booleanoQuery.optional(),
});

export const crearUsuarioSchema = z.strictObject({
  email: emailSchema,
  nombreCompleto: z.string().trim().min(2).max(150),
  password: passwordNuevaSchema,
  rol: z.enum(ROLES),
});

export const cambiarEstadoUsuarioSchema = z.strictObject({ activo: z.boolean() });

export type ListarUsuariosQuery = z.infer<typeof listarUsuariosQuerySchema>;
export type CrearUsuarioDto = z.infer<typeof crearUsuarioSchema>;
export type CambiarEstadoUsuarioDto = z.infer<typeof cambiarEstadoUsuarioSchema>;

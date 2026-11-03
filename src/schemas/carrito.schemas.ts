import { z } from 'zod';
import { idEntero } from './comunes.schemas';

/** Cabecera por la que un invitado (sin sesión) identifica su carrito. */
export const CABECERA_TOKEN_CARRITO = 'x-carrito-token';

/** El token de invitado lo genera SQL Server (NEWID), por eso se acepta cualquier GUID bien formado. */
export const tokenInvitadoSchema = z.guid();

const cantidad = z.number().int('La cantidad debe ser un número entero.').min(1, 'La cantidad mínima es 1.').max(1000, 'La cantidad máxima por producto es 1000.');

export const agregarItemSchema = z.strictObject({ idVariante: idEntero, cantidad });

export const cambiarCantidadSchema = z.strictObject({ cantidad });

export const idVarianteParamSchema = z.strictObject({ idVariante: z.coerce.number().int().positive() });

export const aplicarCuponSchema = z.strictObject({
  codigo: z
    .string()
    .trim()
    .min(3, 'El código del cupón es demasiado corto.')
    .max(50, 'El código del cupón es demasiado largo.')
    .regex(/^[A-Za-z0-9_-]+$/, 'El código solo admite letras, números, guion y guion bajo.'),
});

export type AgregarItemDto = z.infer<typeof agregarItemSchema>;
export type CambiarCantidadDto = z.infer<typeof cambiarCantidadSchema>;
export type AplicarCuponDto = z.infer<typeof aplicarCuponSchema>;

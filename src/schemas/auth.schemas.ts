import { z } from 'zod';

const dentroDelLimiteBcrypt = (valor: string): boolean => Buffer.byteLength(valor, 'utf8') <= 72;
const MENSAJE_LIMITE = 'La contraseña no puede superar 72 bytes (menos caracteres si usa acentos o emojis).';

export const emailSchema = z.string().trim().toLowerCase().email('Correo inválido').max(150);
export const passwordNuevaSchema = z.string().min(8, 'La contraseña debe tener al menos 8 caracteres.').refine(dentroDelLimiteBcrypt, MENSAJE_LIMITE);
const passwordLogin = z.string().min(1, 'La contraseña es obligatoria.').refine(dentroDelLimiteBcrypt, MENSAJE_LIMITE);

export const registroSchema = z.strictObject({ email: emailSchema, nombreCompleto: z.string().trim().min(2).max(150), password: passwordNuevaSchema });
export const inicioSesionSchema = z.strictObject({ email: emailSchema, password: passwordLogin });

// Sirve para renovar y para cerrar sesión: en los dos casos solo llega el refresh token.
export const refreshTokenSchema = z.strictObject({
  refreshToken: z.string().min(20, 'El refresh token no es válido.').max(200, 'El refresh token no es válido.'),
});

export type RegistroDto = z.infer<typeof registroSchema>;
export type InicioSesionDto = z.infer<typeof inicioSesionSchema>;
export type RefreshTokenDto = z.infer<typeof refreshTokenSchema>;

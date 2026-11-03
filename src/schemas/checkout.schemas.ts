import { z } from 'zod';
import { idEntero } from './comunes.schemas';

export const METODOS_PAGO = ['TARJETA', 'TRANSFERENCIA'] as const;

/**
 * El cliente genera UNA llave nueva por cada intento de pago (por ejemplo crypto.randomUUID()) y la reusa
 * si reintenta la misma compra (doble clic o falla de red): así nunca se crean dos pedidos ni dos cobros.
 */
export const pagarSchema = z.strictObject({
  idDireccion: idEntero,
  llaveIdempotencia: z.guid('La llave de idempotencia debe ser un UUID.'),
  metodoPago: z.enum(METODOS_PAGO).default('TARJETA'),
});

export type PagarDto = z.infer<typeof pagarSchema>;

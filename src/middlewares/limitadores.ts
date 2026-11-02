import rateLimit from 'express-rate-limit';
import { env } from '../config/env';

const VENTANA_MS = 15 * 60 * 1000;

const mensaje = {
  error: {
    codigo: 'DEMASIADAS_SOLICITUDES',
    mensaje: 'Demasiadas solicitudes. Espere unos minutos e intente de nuevo.',
  },
};

/** Límite general para toda la API, por IP. */
export const limitadorGeneral = rateLimit({
  windowMs: VENTANA_MS,
  limit: env.RATE_LIMIT_GENERAL_MAX,
  standardHeaders: true,
  legacyHeaders: false,
  message: mensaje,
});

/** Límite estricto para login, registro y refresh (frena la fuerza bruta). */
export const limitadorAutenticacion = rateLimit({
  windowMs: VENTANA_MS,
  limit: env.RATE_LIMIT_AUTH_MAX,
  standardHeaders: true,
  legacyHeaders: false,
  message: mensaje,
});

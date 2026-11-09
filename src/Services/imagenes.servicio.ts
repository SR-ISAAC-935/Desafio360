import { createHash } from 'node:crypto';
import { env } from '../config/env';
import { AppError } from '../errors/AppError';

/**
 * Subida de imágenes a Cloudinary con FIRMA DEL SERVIDOR.
 *
 * El archivo nunca pasa por esta API: el navegador lo sube directo a Cloudinary con una firma que el backend genera aquí,
 * y Cloudinary responde con la URL (secure_url), que luego se guarda en `imagenUrl` al crear o editar el producto.
 * El API secret NUNCA sale del servidor; el cliente solo recibe la firma, que vale 1 hora y solo sirve para estos parámetros.
 */

export const CARPETA_IMAGENES = 'Productos';
export const FORMATOS_PERMITIDOS = 'jpg,jpeg,png,webp';

type ParametrosFirma = Record<string, string | number>;

/**
 * Algoritmo documentado por Cloudinary: parámetros ordenados alfabéticamente como `clave=valor` unidos con `&`,
 * se agrega el API secret al final y se calcula SHA-1 en hexadecimal.
 * (No se firman file, cloud_name, resource_type ni api_key.)
 */
export function firmarParametros(parametros: ParametrosFirma, apiSecret: string): string {
  const texto = Object.keys(parametros)
    .sort()
    .map((clave) => `${clave}=${String(parametros[clave])}`)
    .join('&');
  return createHash('sha1')
    .update(texto + apiSecret)
    .digest('hex');
}

export interface FirmaSubida {
  uploadUrl: string;
  cloudName: string;
  apiKey: string;
  timestamp: number;
  folder: string;
  allowedFormats: string;
  signature: string;
  /** Segundos que Cloudinary acepta esta firma. */
  expiraEnSegundos: number;
}

export function crearFirmaSubida(ahoraMs: number = Date.now()): FirmaSubida {
  const cloudName = env.CLOUDINARY_CLOUD_NAME;
  const apiKey = env.CLOUDINARY_API_KEY;
  const apiSecret = env.CLOUDINARY_API_SECRET;

  if (cloudName === undefined || apiKey === undefined || apiSecret === undefined) {
    throw new AppError(
      503,
      'CLOUDINARY_NO_CONFIGURADO',
      'La subida de imágenes no está configurada. Defina CLOUDINARY_CLOUD_NAME, CLOUDINARY_API_KEY y CLOUDINARY_API_SECRET.',
    );
  }

  const timestamp = Math.floor(ahoraMs / 1000);
  // Todo lo que se firma queda FIJADO: el cliente no puede subir a otra carpeta ni con otros formatos.
  const signature = firmarParametros(
    { allowed_formats: FORMATOS_PERMITIDOS, folder: CARPETA_IMAGENES, timestamp },
    apiSecret,
  );

  return {
    uploadUrl: `https://api.cloudinary.com/v1_1/${cloudName}/image/upload`,
    cloudName,
    apiKey,
    timestamp,
    folder: CARPETA_IMAGENES,
    allowedFormats: FORMATOS_PERMITIDOS,
    signature,
    expiraEnSegundos: 3600,
  };
}

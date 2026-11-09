import { z } from 'zod';
import { env } from '../config/env';
import { idEntero, monto } from './comunes.schemas';

const texto = (max: number) => z.string().trim().min(1).max(max);

/**
 * URL de la imagen de una variante. Solo https (se rechaza javascript:, data:, http:, etc.).
 * Si Cloudinary está configurado, además debe ser una imagen de NUESTRA cuenta: res.cloudinary.com/<cloud_name>/...
 * así el administrador no puede enlazar imágenes de sitios ajenos por error.
 */
export const imagenUrlSchema = z
  .string()
  .trim()
  .max(255)
  .url('La imagen debe ser una URL válida.')
  .refine((valor) => URL.canParse(valor) && new URL(valor).protocol === 'https:', 'La URL de la imagen debe usar https.')
  .refine((valor) => {
    const cuenta = env.CLOUDINARY_CLOUD_NAME;
    // Si no es una URL válida, el chequeo anterior ya la rechaza: aquí no se vuelve a analizar (new URL lanzaría una excepción).
    if (cuenta === undefined || !URL.canParse(valor)) return true;
    const url = new URL(valor);
    return url.hostname === 'res.cloudinary.com' && url.pathname.startsWith(`/${cuenta}/`);
  }, 'La imagen debe subirse a Cloudinary con el endpoint /imagenes/firma.');

/** Una variante nueva: SKU, atributos, precio (con IVA incluido) y existencia inicial. */
export const varianteNuevaSchema = z.strictObject({
  sku: z.string().trim().min(1).max(50).regex(/^[A-Za-z0-9._-]+$/, 'El SKU solo admite letras, números, punto, guion y guion bajo.'),
  talla: texto(30).nullish(),
  color: texto(30).nullish(),
  precio: monto,
  existenciaInicial: z.number().int().min(0).max(1_000_000),
  imagenUrl: imagenUrlSchema.nullish(),
});

export const crearProductoSchema = z.strictObject({
  nombreProducto: z.string().trim().min(2).max(150),
  idCategoria: idEntero,
  descripcion: z.string().trim().max(1000).nullish(),
  variantes: z
    .array(varianteNuevaSchema)
    .min(1, 'El producto debe tener al menos una variante.')
    .max(50)
    .refine(
      (variantes) => new Set(variantes.map((v) => v.sku.toLowerCase())).size === variantes.length,
      'Hay SKU repetidos en las variantes.',
    ),
});

export const actualizarProductoSchema = z.strictObject({
  nombreProducto: z.string().trim().min(2).max(150),
  idCategoria: idEntero,
  descripcion: z.string().trim().max(1000).nullish(),
  activo: z.boolean(),
});

export const actualizarVarianteSchema = z.strictObject({
  talla: texto(30).nullish(),
  color: texto(30).nullish(),
  imagenUrl: imagenUrlSchema.nullish(),
  activo: z.boolean(),
});

export const cambiarPrecioSchema = z.strictObject({ precio: monto });

export type CrearProductoDto = z.infer<typeof crearProductoSchema>;
export type VarianteNuevaDto = z.infer<typeof varianteNuevaSchema>;
export type ActualizarProductoDto = z.infer<typeof actualizarProductoSchema>;
export type ActualizarVarianteDto = z.infer<typeof actualizarVarianteSchema>;
export type CambiarPrecioDto = z.infer<typeof cambiarPrecioSchema>;

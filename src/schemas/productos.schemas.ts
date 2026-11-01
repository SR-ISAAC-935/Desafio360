import { z } from 'zod';
import { idEntero, monto } from './comunes.schemas';

const texto = (max: number) => z.string().trim().min(1).max(max);

/** Una variante nueva: SKU, atributos, precio (con IVA incluido) y existencia inicial. */
export const varianteNuevaSchema = z.strictObject({
  sku: z.string().trim().min(1).max(50).regex(/^[A-Za-z0-9._-]+$/, 'El SKU solo admite letras, números, punto, guion y guion bajo.'),
  talla: texto(30).nullish(),
  color: texto(30).nullish(),
  precio: monto,
  existenciaInicial: z.number().int().min(0).max(1_000_000),
  imagenUrl: z.string().trim().url().max(255).nullish(),
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
  imagenUrl: z.string().trim().url().max(255).nullish(),
  activo: z.boolean(),
});

export const cambiarPrecioSchema = z.strictObject({ precio: monto });

export type CrearProductoDto = z.infer<typeof crearProductoSchema>;
export type VarianteNuevaDto = z.infer<typeof varianteNuevaSchema>;
export type ActualizarProductoDto = z.infer<typeof actualizarProductoSchema>;
export type ActualizarVarianteDto = z.infer<typeof actualizarVarianteSchema>;
export type CambiarPrecioDto = z.infer<typeof cambiarPrecioSchema>;

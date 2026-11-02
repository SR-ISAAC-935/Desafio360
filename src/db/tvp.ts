import sql from 'mssql';

/**
 * Constructores de parámetros con valores de tabla (TVP). El nombre del tipo y el ORDEN de las
 * columnas deben coincidir con los tipos creados en 007_Tipos_Funciones_Vistas.sql.
 */

export interface VarianteNueva {
  sku: string;
  talla?: string | null | undefined;
  color?: string | null | undefined;
  precio: number;
  existenciaInicial: number;
  imagenUrl?: string | null | undefined;
}

export function tablaVariantes(variantes: readonly VarianteNueva[]): sql.Table {
  const tabla = new sql.Table('TT_Catalogo_Variantes');
  tabla.columns.add('SKU', sql.VarChar(50), { nullable: false });
  tabla.columns.add('Talla', sql.NVarChar(30), { nullable: true });
  tabla.columns.add('Color', sql.NVarChar(30), { nullable: true });
  tabla.columns.add('Precio', sql.Decimal(18, 2), { nullable: false });
  tabla.columns.add('ExistenciaInicial', sql.Int, { nullable: false });
  tabla.columns.add('ImagenUrl', sql.NVarChar(255), { nullable: true });
  for (const v of variantes) {
    tabla.rows.add(v.sku, v.talla ?? null, v.color ?? null, v.precio, v.existenciaInicial, v.imagenUrl ?? null);
  }
  return tabla;
}

export function tablaEntradas(entradas: readonly { idVariante: number; cantidad: number }[]): sql.Table {
  const tabla = new sql.Table('TT_Inventario_Entradas');
  tabla.columns.add('IDVariante', sql.Int, { nullable: false });
  tabla.columns.add('Cantidad', sql.Int, { nullable: false });
  for (const e of entradas) {
    tabla.rows.add(e.idVariante, e.cantidad);
  }
  return tabla;
}

export function tablaDevoluciones(lineas: readonly { idPedidoDetalle: number; cantidad: number }[]): sql.Table {
  const tabla = new sql.Table('TT_Devoluciones_Lineas');
  tabla.columns.add('IDPedidoDetalle', sql.Int, { nullable: false });
  tabla.columns.add('Cantidad', sql.Int, { nullable: false });
  for (const l of lineas) {
    tabla.rows.add(l.idPedidoDetalle, l.cantidad);
  }
  return tabla;
}

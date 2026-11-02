import sql from 'mssql';
import { env } from '../config/env';

const configuracion: sql.config = {
  server: env.DB_SERVER,
  database: env.DB_NAME,
  user: env.DB_USER,
  password: env.DB_PASSWORD,
  // Con instancia con nombre (SQLEXPRESS) no se indica puerto
  ...(env.DB_INSTANCE ? {} : { port: env.DB_PORT }),
  options: {
    encrypt: env.DB_ENCRYPT,
    trustServerCertificate: env.DB_TRUST_SERVER_CERT,
    ...(env.DB_INSTANCE ? { instanceName: env.DB_INSTANCE } : {}),
  },
  pool: { max: 10, min: 0, idleTimeoutMillis: 30_000 },
  connectionTimeout: 15_000,
  requestTimeout: 30_000,
};

let promesaPool: Promise<sql.ConnectionPool> | null = null;

function crearPool(): Promise<sql.ConnectionPool> {
  const pool = new sql.ConnectionPool(configuracion);
  pool.on('error', (error) => console.error('Error en el pool de SQL Server:', error));

  const promesa = pool.connect().catch((error: unknown) => {
    promesaPool = null; // permite reintentar la próxima vez
    throw error;
  });
  return promesa;
}

/** Devuelve el pool compartido (se crea en la primera llamada y se reconecta si se cayó). */
export async function obtenerPool(): Promise<sql.ConnectionPool> {
  if (promesaPool) {
    const existente = await promesaPool;
    if (existente.connected) return existente;

    promesaPool = null;
    await existente.close().catch(() => undefined);
  }
  promesaPool = crearPool();
  return promesaPool;
}

export async function cerrarPool(): Promise<void> {
  if (!promesaPool) return;
  const pool = await promesaPool.catch(() => null);
  promesaPool = null;
  await pool?.close().catch(() => undefined);
}

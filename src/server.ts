import { app } from './app';
import { env } from './config/env';
import { cerrarPool, obtenerPool } from './db/pool';

async function iniciar(): Promise<void> {
  // Falla rápido y con un mensaje claro si la base de datos no responde
  await obtenerPool();

  const servidor = app.listen(env.PORT, () => {
    console.log(`API de ShopCart escuchando en http://localhost:${env.PORT} (${env.NODE_ENV})`);
  });

  const apagar = (senal: string): void => {
    console.log(`Señal ${senal} recibida: cerrando...`);
    servidor.close(() => {
      void cerrarPool().finally(() => process.exit(0));
    });
    setTimeout(() => process.exit(1), 10_000).unref();
  };

  process.on('SIGINT', () => apagar('SIGINT'));
  process.on('SIGTERM', () => apagar('SIGTERM'));
}

process.on('unhandledRejection', (motivo) => {
  console.error('Promesa rechazada sin manejar:', motivo);
});

iniciar().catch((error: unknown) => {
  console.error('No se pudo iniciar la API:', error);
  process.exit(1);
});

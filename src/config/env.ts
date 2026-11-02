import { z } from 'zod';

// Node 20.12+ trae lector de .env integrado. Si el archivo no existe (producción), se ignora.
try {
  process.loadEnvFile();
} catch {
  /* sin archivo .env: se usan las variables del entorno */
}

const booleano = z
  .enum(['true', 'false'])
  .default('false')
  .transform((valor) => valor === 'true');

const esquema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),

  CORS_ORIGINS: z
    .string()
    .default('http://localhost:5173')
    .transform((texto) =>
      texto
        .split(',')
        .map((origen) => origen.trim())
        .filter((origen) => origen.length > 0),
    ),

  DB_SERVER: z.string().min(1, 'DB_SERVER es obligatorio'),
  DB_PORT: z.coerce.number().int().min(1).max(65535).default(1433),
  DB_INSTANCE: z.string().optional(),
  DB_NAME: z.string().min(1).default('ShopCart'),
  DB_USER: z.string().min(1, 'DB_USER es obligatorio'),
  DB_PASSWORD: z.string().min(1, 'DB_PASSWORD es obligatorio'),
  DB_ENCRYPT: booleano,
  DB_TRUST_SERVER_CERT: booleano,

  JWT_SECRET: z.string().min(32, 'JWT_SECRET debe tener al menos 32 caracteres'),
  JWT_ACCESS_MINUTES: z.coerce.number().int().min(1).max(120).default(15),
  REFRESH_TOKEN_DAYS: z.coerce.number().int().min(1).max(90).default(7),
  BCRYPT_ROUNDS: z.coerce.number().int().min(8).max(14).default(10),

  RATE_LIMIT_GENERAL_MAX: z.coerce.number().int().min(10).default(300),
  RATE_LIMIT_AUTH_MAX: z.coerce.number().int().min(1).default(20),
});

const resultado = esquema.safeParse(process.env);

if (!resultado.success) {
  console.error('Configuración inválida. Revise su archivo .env:');
  for (const problema of resultado.error.issues) {
    console.error(`  - ${problema.path.join('.')}: ${problema.message}`);
  }
  process.exit(1);
}

export const env = resultado.data;

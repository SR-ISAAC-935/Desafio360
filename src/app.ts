import express from 'express';
import { rutasDocs } from './docs/swagger';
import cors from 'cors';
import helmet from 'helmet';
import { env } from './config/env';
import { limitadorGeneral } from './middlewares/limitadores';
import { manejadorErrores, rutaNoEncontrada } from './middlewares/errores';
import { rutas } from './routes';

// La app se crea aquí y se arranca en server.ts: así se puede importar en pruebas sin abrir un puerto.
export const app = express();

app.use('/api', rutasDocs);
app.disable('x-powered-by');
app.use(helmet());
app.use(
  cors({
    origin: env.CORS_ORIGINS, // lista explícita de orígenes, nunca "*"
    methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
    allowedHeaders: ['Content-Type', 'Authorization','x-carrito-token'],
    maxAge: 600,
  }),
);
app.use(express.json({ limit: '100kb' }));

app.use('/api', limitadorGeneral, rutas);

app.use(rutaNoEncontrada);
app.use(manejadorErrores);

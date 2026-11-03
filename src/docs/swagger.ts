import { Router } from 'express';
import helmet from 'helmet';
import swaggerUi from 'swagger-ui-express';
import { construirOpenApi } from './openapi';

/**
 * Documentación interactiva en /api/docs y especificación cruda en /api/docs.json.
 *
 * Se monta ANTES del helmet global de app.ts porque Swagger UI necesita una política de seguridad de contenido
 * más laxa (scripts y estilos propios). Solo afecta a estas dos rutas: el resto de la API conserva la política estricta.
 */
export const rutasDocs = Router();

rutasDocs.use(['/docs', '/docs.json'], helmet({ contentSecurityPolicy: false }));

const especificacion = construirOpenApi('/api');

rutasDocs.get('/docs.json', (_req, res) => {
  res.json(especificacion);
});

rutasDocs.use(
  '/docs',
  swaggerUi.serve,
  swaggerUi.setup(especificacion, {
    customSiteTitle: 'ShopCart API – Documentación',
    swaggerOptions: { persistAuthorization: true, docExpansion: 'list', tagsSorter: 'alpha' },
  }),
);

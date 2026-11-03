/**
 * Comprueba que la documentación OpenAPI:
 *  1) es una especificación válida;
 *  2) documenta EXACTAMENTE los endpoints que existen en las rutas de Express (ninguno de más, ninguno de menos);
 *  3) tiene ejemplos que el propio esquema Zod acepta (un ejemplo inválido confundiría a quien lo use);
 *  4) se sirve correctamente en /api/docs y /api/docs.json.
 *
 * Ejecutar:  pnpm docs:validar
 */
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import type { AddressInfo } from 'node:net';
import SwaggerParser from '@apidevtools/swagger-parser';

// El módulo de configuración exige estas variables; aquí no se usa la base de datos.
process.env['JWT_SECRET'] ??= 'x'.repeat(40);
process.env['DB_SERVER'] ??= 'localhost';
process.env['DB_NAME'] ??= 'x';
process.env['DB_USER'] ??= 'x';
process.env['DB_PASSWORD'] ??= 'x';

let fallos = 0;
const verificar = (condicion: boolean, mensaje: string): void => {
  if (condicion) return;
  fallos += 1;
  console.error(`  ✗ ${mensaje}`);
};

/** Lee las rutas reales de src/routes: método + ruta completa (con el prefijo con el que se montan en index.ts). */
function rutasReales(): Set<string> {
  const dir = join(__dirname, '..', 'src', 'routes');
  const indice = readFileSync(join(dir, 'index.ts'), 'utf8');
  const prefijos = new Map<string, string>();
  for (const [, prefijo, variable] of indice.matchAll(/rutas\.use\('([^']+)'(?:,[^)]*?)?,\s*(rutas\w+)\)/g)) {
    prefijos.set(variable as string, prefijo as string);
  }
  const reales = new Set<string>(['get /salud']);
  for (const archivo of readdirSync(dir).filter((f) => f.endsWith('.ts') && f !== 'index.ts')) {
    const texto = readFileSync(join(dir, archivo), 'utf8');
    for (const [, variable, metodo, ruta] of texto.matchAll(/(rutas\w+)\.(get|post|put|patch|delete)\(\s*'([^']*)'/g)) {
      const prefijo = prefijos.get(variable as string);
      if (prefijo === undefined) { verificar(false, `no se encontró el prefijo de ${variable} en routes/index.ts`); continue; }
      const completa = `${prefijo}${ruta === '/' ? '' : ruta}`.replace(/:(\w+)/g, '{$1}');
      reales.add(`${metodo} ${completa}`);
    }
  }
  return reales;
}

async function principal(): Promise<void> {
  const { construirOpenApi, endpointsDocumentados } = await import('../src/docs/openapi.js');
  const { app } = await import('../src/app.js');

  console.log('1) Especificación válida');
  const espec = construirOpenApi('/api');
  try {
    await SwaggerParser.validate(JSON.parse(JSON.stringify(espec)));
  } catch (error) {
    verificar(false, `la especificación no es válida: ${(error as Error).message}`);
  }

  console.log('2) Cobertura: lo documentado coincide con las rutas reales');
  const documentados = new Set(endpointsDocumentados().map((e) => `${e.metodo} ${e.ruta}`));
  const reales = rutasReales();
  for (const r of reales) verificar(documentados.has(r), `falta documentar: ${r}`);
  for (const d of documentados) verificar(reales.has(d), `documentado pero no existe en las rutas: ${d}`);
  console.log(`   ${reales.size} rutas reales, ${documentados.size} documentadas`);

  console.log('3) Los ejemplos pasan la validación Zod real');
  for (const e of endpointsDocumentados()) {
    if (e.cuerpo && e.ejemplo !== undefined) {
      const resultado = e.cuerpo.safeParse(e.ejemplo);
      verificar(resultado.success, `ejemplo inválido en ${e.metodo.toUpperCase()} ${e.ruta}: ${resultado.success ? '' : JSON.stringify(resultado.error.issues)}`);
    }
    if (e.cuerpo && e.ejemplo === undefined && ['post', 'put', 'patch'].includes(e.metodo)) {
      // Los endpoints sin ejemplo deben ser pocos y triviales; solo se informa.
    }
  }

  console.log('4) Se sirve en /api/docs y /api/docs.json');
  const servidor = app.listen(0);
  try {
    const { port } = servidor.address() as AddressInfo;
    const json = await fetch(`http://127.0.0.1:${port}/api/docs.json`);
    verificar(json.status === 200, `/api/docs.json respondió ${json.status}`);
    const cuerpo = (await json.json()) as { openapi?: string; paths?: object };
    verificar(cuerpo.openapi === '3.0.3' && Object.keys(cuerpo.paths ?? {}).length > 20, '/api/docs.json no devolvió la especificación');
    const html = await fetch(`http://127.0.0.1:${port}/api/docs/`);
    verificar(html.status === 200, `/api/docs/ respondió ${html.status}`);
    const texto = await html.text();
    verificar(texto.includes('swagger-ui'), '/api/docs/ no devolvió la página de Swagger UI');
    const otra = await fetch(`http://127.0.0.1:${port}/api/no-existe`);
    verificar(otra.status === 404, 'una ruta inexistente ya no responde 404');
    const csp = otra.headers.get('content-security-policy');
    verificar(csp !== null && csp.includes("default-src 'self'"), 'el resto de la API perdió la política de seguridad estricta (helmet)');
  } finally {
    servidor.close();
  }

  console.log(fallos === 0 ? '\nOK: documentación válida y completa.' : `\n${fallos} problema(s).`);
  process.exit(fallos === 0 ? 0 : 1);
}

void principal();

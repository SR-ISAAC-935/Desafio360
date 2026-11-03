// Se importa PRIMERO en las pruebas: deja el entorno listo antes de que se cargue la configuración.
// Los límites de solicitudes se suben para que las ~1000 peticiones de la prueba no reciban 429.
process.env['RATE_LIMIT_GENERAL_MAX'] = '1000000';
process.env['RATE_LIMIT_AUTH_MAX'] = '1000000';
// Valores de relleno si no hay .env: la prueba NUNCA se conecta a la base de datos (usa una simulada).
process.env['DB_SERVER'] ??= 'simulada';
process.env['DB_USER'] ??= 'simulado';
process.env['DB_PASSWORD'] ??= 'simulada';
process.env['JWT_SECRET'] ??= 'clave-de-prueba-de-al-menos-32-caracteres-xx';

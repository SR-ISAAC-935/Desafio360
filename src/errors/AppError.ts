/**
 * Error controlado de la aplicación: lleva el código HTTP, un código corto y un mensaje
 * apto para mostrar al usuario. El manejador central lo convierte en la respuesta JSON.
 */
export class AppError extends Error {
  constructor(
    public readonly estado: number,
    public readonly codigo: string,
    mensaje: string,
    public readonly detalles?: unknown,
  ) {
    super(mensaje);
    this.name = 'AppError';
  }
}

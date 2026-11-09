import type { Request, Response } from 'express';
import { crearFirmaSubida } from '../Services/imagenes.servicio';

/** Entrega los datos para que el navegador suba una imagen directo a Cloudinary. La firma no se guarda en caché. */
export function firma(_req: Request, res: Response): void {
  res.setHeader('Cache-Control', 'no-store');
  res.json(crearFirmaSubida());
}

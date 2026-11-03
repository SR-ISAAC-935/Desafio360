import type { UsuarioAutenticado } from '../Services/tokens.servicio';

// Agrega req.usuario a los tipos de Express (lo llena el middleware "autenticar")
declare global {
  namespace Express {
    interface Request {
      usuario?: UsuarioAutenticado;
    }
  }
}

export {};

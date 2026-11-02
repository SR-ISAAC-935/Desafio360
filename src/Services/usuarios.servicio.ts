import bcrypt from 'bcryptjs';
import { env } from '../config/env';
import { ejecutarSP, type Fila } from '../db/ejecutarSP';
import { P } from '../db/parametros';
import { AppError } from '../errors/AppError';
import type { CambiarEstadoUsuarioDto, CrearUsuarioDto, ListarUsuariosQuery } from '../schemas/usuarios.schemas';

export async function listarUsuarios(idAdmin: number, q: ListarUsuariosQuery): Promise<Fila[]> {
  const resultado = await ejecutarSP('SP_Usuarios_Listar', [
    P.int('IDUsuarioAccion', idAdmin),
    P.nvarchar('Buscar', 100, q.texto),
    P.nvarchar('NombreRol', 50, q.rol),
    P.bit('Activo', q.activo),
    P.int('Pagina', q.pagina),
    P.int('TamanoPagina', q.tamanoPagina),
  ]);
  return resultado.filas<Fila>();
}

export async function crearUsuario(idAdmin: number, datos: CrearUsuarioDto): Promise<{ IDUsuario: number }> {
  const hash = await bcrypt.hash(datos.password, env.BCRYPT_ROUNDS);

  const resultado = await ejecutarSP('SP_Usuarios_Crear', [
    P.nvarchar('Email', 150, datos.email),
    P.nvarchar('NombreCompleto', 150, datos.nombreCompleto),
    P.varchar('PasswordHash', 255, hash),
    P.nvarchar('NombreRol', 50, datos.rol),
    P.int('IDUsuarioAccion', idAdmin),
  ]);

  const fila = resultado.primera<{ IDUsuario: number }>();
  if (!fila) throw new AppError(500, 'ERROR_INTERNO', 'No se pudo crear el usuario.');
  return fila;
}

/** Desactiva o reactiva (sin borrar). Al desactivar, el procedimiento cierra todas sus sesiones. */
export async function cambiarEstadoUsuario(idAdmin: number, idUsuario: number, datos: CambiarEstadoUsuarioDto): Promise<void> {
  await ejecutarSP('SP_Usuarios_CambiarEstado', [
    P.int('IDUsuario', idUsuario),
    P.bit('Activo', datos.activo),
    P.int('IDUsuarioAccion', idAdmin),
  ]);
}

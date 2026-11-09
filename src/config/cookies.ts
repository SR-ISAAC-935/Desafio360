import { env } from './env';

export const refreshCookieOptions = {
    httpOnly: true,
    secure: env.NODE_ENV === 'production',
    sameSite: 'lax' as const,
    path: '/api/auth',
    maxAge: env.REFRESH_TOKEN_DAYS * 24 * 60 * 60 * 1000
};
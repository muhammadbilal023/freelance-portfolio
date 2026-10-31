import type { NextFunction, Request, Response } from 'express';
import type { Logger } from 'pino';
import { ZodError } from 'zod';
import { ApiError } from '../utils/api-error.js';

export function notFoundHandler(req: Request, _res: Response, next: NextFunction): void {
  next(new ApiError(404, 'not_found', `Route ${req.method} ${req.path} not found`));
}

/**
 * Central error handler: converts any thrown value into a consistent JSON
 * envelope `{ error: { code, message, details? } }` and logs it.
 * Provider internals are never exposed to clients.
 */
export function createErrorHandler(logger: Logger) {
  return (err: unknown, req: Request, res: Response, _next: NextFunction): void => {
    let apiError: ApiError;

    if (err instanceof ApiError) {
      apiError = err;
    } else if (err instanceof ZodError) {
      apiError = ApiError.badRequest('validation_error', 'Request is invalid', err.issues);
    } else {
      apiError = ApiError.internal();
      logger.error({ err, path: req.path }, 'unhandled error');
    }

    const logPayload = { path: req.path, method: req.method, code: apiError.code };
    if (apiError.status >= 500) {
      logger.error(logPayload, apiError.message);
    } else {
      logger.warn({ ...logPayload, err }, apiError.message);
    }

    res.status(apiError.status).json({
      error: {
        code: apiError.code,
        message: apiError.message,
        ...(apiError.details !== undefined ? { details: apiError.details } : {}),
      },
    });
  };
}

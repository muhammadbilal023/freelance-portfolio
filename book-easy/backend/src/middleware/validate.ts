import type { NextFunction, Request, RequestHandler, Response } from 'express';
import { ZodError, type ZodTypeAny } from 'zod';
import { ApiError } from '../utils/api-error.js';

/**
 * Validates and replaces `req.body` with the parsed (and transformed) output
 * of the given Zod schema, so handlers always receive typed, clean data.
 */
export function validateBody<T extends ZodTypeAny>(schema: T): RequestHandler {
  return (req: Request, _res: Response, next: NextFunction) => {
    try {
      req.body = schema.parse(req.body) as unknown;
      next();
    } catch (err) {
      if (err instanceof ZodError) {
        const details = err.issues.map((i) => ({
          field: i.path.join('.'),
          message: i.message,
        }));
        next(ApiError.badRequest('validation_error', 'Request body is invalid', details));
        return;
      }
      next(err);
    }
  };
}

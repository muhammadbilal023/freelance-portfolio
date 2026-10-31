/**
 * Operational error with an HTTP status and a stable machine-readable code.
 * Thrown anywhere in the app and translated to a JSON response by the
 * central error handler — controllers never build error responses by hand.
 */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
    this.name = 'ApiError';
  }

  static badRequest(code: string, message: string, details?: unknown): ApiError {
    return new ApiError(400, code, message, details);
  }

  static internal(message = 'Unexpected server error'): ApiError {
    return new ApiError(500, 'internal_error', message);
  }
}

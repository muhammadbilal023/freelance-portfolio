/**
 * Error type carrying an HTTP status and a stable machine-readable code.
 * The central error handler serialises it as `{ error: { code, message, details? } }`.
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

  static unauthorized(code: string, message: string): ApiError {
    return new ApiError(401, code, message);
  }

  static notFound(message = 'Resource not found'): ApiError {
    return new ApiError(404, 'not_found', message);
  }

  /** The endpoint is deployed but its credentials are not configured. */
  static notConfigured(what: string): ApiError {
    return new ApiError(503, 'not_configured', `${what} is not configured on this server`);
  }

  static internal(message = 'Internal server error'): ApiError {
    return new ApiError(500, 'internal_error', message);
  }
}

/** Thrown by integration clients when a provider asks us to slow down. */
export class RateLimitError extends Error {
  constructor(readonly retryAfterMs: number, message = 'Rate limited by provider') {
    super(message);
    this.name = 'RateLimitError';
  }
}

/** Thrown when a flow runs but its integration credentials are missing. */
export class ConfigError extends Error {
  constructor(what: string) {
    super(`${what} is not configured — set the corresponding environment variables`);
    this.name = 'ConfigError';
  }
}

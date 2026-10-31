"""Error types and the consistent JSON error envelope.

Every failure the API returns looks like:
    {"error": {"code": "...", "message": "...", "details": {...}}}
so clients (and tests) can rely on stable codes instead of prose.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.details = details

    @classmethod
    def bad_request(
        cls, code: str, message: str, details: dict[str, Any] | None = None
    ) -> ApiError:
        return cls(400, code, message, details)

    @classmethod
    def unauthorized(cls, code: str, message: str) -> ApiError:
        return cls(401, code, message)

    @classmethod
    def not_found(cls, what: str) -> ApiError:
        return cls(404, "not_found", f"{what} not found")

    @classmethod
    def not_configured(cls, feature: str, message: str) -> ApiError:
        return cls(503, "not_configured", message)

    @classmethod
    def from_config_error(cls, exc: ConfigError) -> ApiError:
        return cls(503, "not_configured", f"{exc.what} is not configured")

    @classmethod
    def internal(cls, message: str) -> ApiError:
        return cls(500, "internal_error", message)

    def to_response(self) -> JSONResponse:
        body: dict[str, Any] = {"error": {"code": self.code, "message": self.message}}
        if self.details:
            body["error"]["details"] = self.details
        return JSONResponse(body, status_code=self.status)


class RateLimitError(ApiError):
    """Raised by the limiter middleware; Retry-After tells clients when to come back."""

    def __init__(self, retry_after_seconds: float):
        super().__init__(429, "rate_limited", "Too many requests, slow down.")
        self.retry_after_seconds = max(1.0, round(retry_after_seconds))

    def to_response(self) -> JSONResponse:
        response = super().to_response()
        response.headers["Retry-After"] = str(int(self.retry_after_seconds))
        return response


class ConfigError(Exception):
    """A feature was invoked without the credentials/settings it needs."""

    def __init__(self, what: str):
        super().__init__(f"{what} is not configured")
        self.what = what


def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def handle_api_error(_request: Request, exc: ApiError) -> JSONResponse:
        return exc.to_response()

    @app.exception_handler(StarletteHTTPException)
    async def handle_http(_request: Request, exc: StarletteHTTPException) -> JSONResponse:
        # Normalize FastAPI/Starlette's own 404/405 into our envelope.
        if exc.status_code in (404, 405):
            code = "not_found" if exc.status_code == 404 else "method_not_allowed"
            return JSONResponse(
                {"error": {"code": code, "message": str(exc.detail)}},
                status_code=exc.status_code,
            )
        return JSONResponse(
            {"error": {"code": "http_error", "message": str(exc.detail)}},
            status_code=exc.status_code,
        )

    @app.exception_handler(RequestValidationError)
    async def handle_validation(_request: Request, exc: RequestValidationError) -> JSONResponse:
        return JSONResponse(
            {
                "error": {
                    "code": "invalid_request",
                    "message": "Request validation failed.",
                    "details": {"errors": exc.errors()},
                }
            },
            status_code=422,
        )

    @app.exception_handler(Exception)
    async def handle_unexpected(request: Request, exc: Exception) -> JSONResponse:
        import logging

        logging.getLogger("askdocs").error(
            "unhandled exception",
            extra={"extras": {"path": request.url.path, "error": str(exc)}},
            exc_info=exc,
        )
        return JSONResponse(
            {"error": {"code": "internal_error", "message": "Unexpected server error."}},
            status_code=500,
        )

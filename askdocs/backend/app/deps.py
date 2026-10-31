"""Shared request helpers: container access and current-user resolution."""

from __future__ import annotations

from typing import TYPE_CHECKING

from fastapi import Request

from app.errors import RateLimitError
from app.rate_limit import TokenBucketLimiter

if TYPE_CHECKING:
    from app.main import Container


def get_container(request: Request) -> Container:
    return request.app.state.container  # type: ignore[no-any-return]


def get_user_id(request: Request) -> str:
    """Identity is a simple X-User-Id header (full auth is out of scope; see README)."""
    user_id = request.headers.get("x-user-id", "").strip()
    return user_id or "anon"


def get_limiter(request: Request) -> TokenBucketLimiter:
    return get_container(request).limiter


def enforce_rate_limit(request: Request) -> str:
    """FastAPI dependency: consume a token for the current user or 429."""
    user_id = get_user_id(request)
    allowed, retry_after = get_limiter(request).try_acquire(user_id)
    if not allowed:
        raise RateLimitError(retry_after)
    return user_id

"""GET /health - liveness plus live queue/document counters (Docker healthcheck)."""

from __future__ import annotations

import time

from fastapi import APIRouter, Request

from app.deps import get_container

router = APIRouter()

_STARTED = time.monotonic()


@router.get("/health")
async def health(request: Request) -> dict[str, object]:
    c = get_container(request)
    return {
        "status": "ok",
        "uptime_seconds": round(time.monotonic() - _STARTED, 1),
        "llm_provider": c.settings.llm_provider,
        "documents": c.documents.count(),
        "chunks_indexed": c.vectors.count(),
        "jobs": c.jobs.count_by_status(),
        "dead_letters": c.dead_letters.count(),
    }

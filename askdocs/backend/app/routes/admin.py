"""Admin JSON API: recent events/jobs/dead-letters + manual retry.

Kept unauthenticated for the demo (documented limitation); in real deployment
this would sit behind an operator auth layer. Retries reuse the queue, so a
manual retry is just a fresh, fully-tracked job.
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Request

from app.deps import get_container
from app.errors import ApiError
from app.handoff.handoff import HANDOFF_JOB, enqueue_handoff

router = APIRouter(prefix="/admin/api", tags=["admin"])


def _parse_limit(raw: str | None, default: int = 50) -> int:
    try:
        value = int(raw) if raw is not None else default
    except (TypeError, ValueError):
        return default
    return max(1, min(200, value))


@router.get("/summary")
async def summary(request: Request) -> dict[str, Any]:
    c = get_container(request)
    return {
        "documents": c.documents.count(),
        "chunks_indexed": c.vectors.count(),
        "jobs": c.jobs.count_by_status(),
        "feedback": c.feedback.counts(),
    }


@router.get("/jobs")
async def list_jobs(request: Request, limit: str | None = None) -> dict[str, Any]:
    c = get_container(request)
    jobs = [
        {
            "id": j.id,
            "type": j.type,
            "status": j.status,
            "attempts": j.attempts,
            "max_attempts": j.max_attempts,
            "last_error": j.last_error,
        }
        for j in c.jobs.list_recent(_parse_limit(limit))
    ]
    return {"jobs": jobs, "counts": c.jobs.count_by_status()}


@router.get("/dead-letters")
async def list_dead_letters(request: Request, limit: str | None = None) -> dict[str, Any]:
    c = get_container(request)
    return {"dead_letters": c.dead_letters.list_recent(_parse_limit(limit))}


@router.get("/events")
async def list_events(request: Request, limit: str | None = None) -> dict[str, Any]:
    c = get_container(request)
    return {"events": c.events.list_recent(_parse_limit(limit))}


@router.post("/jobs/{job_id}/retry")
async def retry_job(request: Request, job_id: str) -> dict[str, Any]:
    c = get_container(request)
    try:
        numeric = int(job_id)
    except ValueError:
        raise ApiError.bad_request("invalid_id", "Job id must be an integer.") from None
    if c.jobs.get(numeric) is None:
        raise ApiError.not_found("Job")
    if not c.jobs.reset_to_queued(numeric):
        raise ApiError.bad_request("not_retryable", "Only dead or succeeded jobs can be retried.")
    return {"retried": True, "jobId": numeric}


@router.post("/dead-letters/{dead_letter_id}/retry")
async def retry_dead_letter(request: Request, dead_letter_id: str) -> dict[str, Any]:
    c = get_container(request)
    try:
        numeric = int(dead_letter_id)
    except ValueError:
        raise ApiError.bad_request("invalid_id", "Dead-letter id must be an integer.") from None
    dl = c.dead_letters.get(numeric)
    if dl is None:
        raise ApiError.not_found("Dead letter")
    job_id = c.jobs.enqueue(dl["type"], dl["payload"], c.settings.job_max_attempts)
    c.dead_letters.mark_retried(numeric)
    return {"retried": True, "jobId": job_id, "deadLetterId": numeric}


@router.post("/sessions/{session_id}/handoff")
async def trigger_handoff(request: Request, session_id: str) -> dict[str, Any]:
    """Manual 'escalate to a human' (used by the dashboard / Talk-to-human button)."""
    c = get_container(request)
    if c.sessions.get(session_id) is None:
        raise ApiError.not_found("Session")
    last_assistant = [m for m in c.messages.history(session_id, limit=200) if m.role == "assistant"]
    trigger_id = last_assistant[-1].id if last_assistant else 0
    job_id = await enqueue_handoff(
        c, session_id=session_id, trigger_message_id=trigger_id, reason="user_requested"
    )
    return {"queued": job_id is not None, "jobId": job_id, "jobType": HANDOFF_JOB}

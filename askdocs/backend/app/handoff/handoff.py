"""Handoff orchestration: detect -> summarize -> enqueue -> (runner) deliver."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from app.errors import ConfigError
from app.handoff.summary import build_summary
from app.queue.job_runner import JobHandler

if TYPE_CHECKING:
    from app.main import Container

HANDOFF_JOB = "handoff.create_ticket"


async def enqueue_handoff(
    container: Container, *, session_id: str, trigger_message_id: int, reason: str
) -> int | None:
    """Queue a ticket for a handoff. Returns job id, or None if already triggered.

    Idempotency is on the triggering message id, so a retried/duplicated chat
    answer (or a double-clicked "talk to a human") can't open two tickets.
    """
    key = f"{session_id}:{trigger_message_id}"
    if not container.events.record("handoff", key, reason, {"session_id": session_id}):
        return None

    transcript = container.messages.history(session_id, limit=40)
    last_question = next((m.content for m in reversed(transcript) if m.role == "user"), "")
    summary = await build_summary(container.llm, transcript, last_question, reason)
    payload: dict[str, Any] = {
        "session_id": session_id,
        "trigger_message_id": trigger_message_id,
        "reason": reason,
        "summary": summary,
        "transcript_excerpt": [{"role": m.role, "content": m.content} for m in transcript][-8:],
    }
    job_id = container.jobs.enqueue(HANDOFF_JOB, payload, container.settings.job_max_attempts)
    container.logger.info(
        "handoff enqueued",
        extra={"extras": {"job_id": job_id, "session_id": session_id, "reason": reason}},
    )
    return job_id


def make_handler(container: Container) -> JobHandler:
    """Build the job handler bound to a container's ticket client + notifier."""

    def handle(payload: dict[str, Any]) -> None:
        s = payload["summary"]
        link = (
            f"{container.settings.public_base_url}/chat/sessions/{payload['session_id']}/messages"
        )
        fields = {
            "Issue": s.get("issue", ""),
            "Attempted": s.get("attempted", ""),
            "Urgency": s.get("urgency", "normal"),
            "Reason": payload["reason"],
            "Session": payload["session_id"],
            "Status": "Open",
            "Transcript Link": link,
        }
        url = container.ticket_client.create_ticket(fields)  # ConfigError -> dead-letter
        try:
            container.notifier.notify(
                f"🎟 New support ticket ({fields['Urgency']}): {fields['Issue']} → {url}"
            )
        except ConfigError:
            container.logger.info("Slack not configured; skipped notification")

    return handle

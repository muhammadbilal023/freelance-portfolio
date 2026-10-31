"""Feedback endpoint (helpful / not helpful) stored for evaluation."""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from app.deps import enforce_rate_limit, get_container
from app.errors import ApiError
from app.handoff.handoff import enqueue_handoff
from app.schemas import FeedbackRequest

router = APIRouter(tags=["feedback"])


@router.post("/feedback")
async def submit_feedback(
    request: Request, body: FeedbackRequest, _user: str = Depends(enforce_rate_limit)
):
    c = get_container(request)
    message = c.messages.get(body.message_id)
    if message is None:
        raise ApiError.not_found("Message")
    c.feedback.add(body.message_id, message.session_id, body.rating)
    negatives = c.feedback.negative_count_for_session(message.session_id)

    # A streak of "not helpful" ratings is a silent request for a human. Fire once,
    # on the exact threshold crossing, so later negatives don't open duplicate tickets.
    handoff_job_id = None
    if body.rating == "not_helpful" and negatives == c.settings.handoff_neg_feedback_threshold:
        handoff_job_id = await enqueue_handoff(
            c,
            session_id=message.session_id,
            trigger_message_id=body.message_id,
            reason="negative_feedback",
        )
    return {
        "recorded": True,
        "message_id": body.message_id,
        "rating": body.rating,
        "session_negative_count": negatives,
        "handoff_job_id": handoff_job_id,
    }

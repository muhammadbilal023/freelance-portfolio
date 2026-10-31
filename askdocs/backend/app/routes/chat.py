"""Chat endpoints: blocking answer, SSE streaming, and session history."""

from __future__ import annotations

import json
from collections.abc import AsyncIterator

from fastapi import APIRouter, Depends, Request
from fastapi.responses import StreamingResponse

from app.chat import service
from app.deps import enforce_rate_limit, get_container
from app.handoff.handoff import enqueue_handoff
from app.schemas import ChatRequest

router = APIRouter(prefix="/chat", tags=["chat"])


@router.post("")
async def chat(request: Request, body: ChatRequest, user_id: str = Depends(enforce_rate_limit)):
    c = get_container(request)
    prepared = await service.prepare_turn(c, user_id, body.session_id, body.question)
    answer = await service.answer_blocking(c, prepared)
    handoff_job_id = None
    if answer.needs_handoff:
        reason = "user_requested" if prepared.needs_human else "model_fallback"
        handoff_job_id = await enqueue_handoff(
            c,
            session_id=prepared.session_id,
            trigger_message_id=answer.message_id,
            reason=reason,
        )
    return {
        "session_id": prepared.session_id,
        "answer": answer.text,
        "citations": answer.citations,
        "message_id": answer.message_id,
        "needs_handoff": answer.needs_handoff,
        "handoff_job_id": handoff_job_id,
    }


def _sse(event: str, data: object) -> str:
    return f"event: {event}\ndata: {json.dumps(data)}\n\n"


@router.post("/stream")
async def chat_stream(
    request: Request, body: ChatRequest, user_id: str = Depends(enforce_rate_limit)
) -> StreamingResponse:
    c = get_container(request)
    prepared = await service.prepare_turn(c, user_id, body.session_id, body.question)

    async def encode() -> AsyncIterator[str]:
        # Echo the (possibly newly-created) session id first so the client can keep
        # the conversation continuous across turns.
        yield _sse("session", {"session_id": prepared.session_id})
        reason = "user_requested" if prepared.needs_human else "model_fallback"
        async for event, data in service.stream_answer(c, prepared):
            yield _sse(event, data)
            if event == "done" and data.get("needs_handoff"):
                job_id = await enqueue_handoff(
                    c,
                    session_id=prepared.session_id,
                    trigger_message_id=data["message_id"],
                    reason=reason,
                )
                yield _sse("handoff", {"job_id": job_id})

    return StreamingResponse(
        encode(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@router.get("/sessions/{session_id}/messages")
async def session_messages(request: Request, session_id: str) -> dict[str, object]:
    c = get_container(request)
    if c.sessions.get(session_id) is None:
        return {"messages": []}
    messages = [
        {
            "id": m.id,
            "role": m.role,
            "content": m.content,
            "citations": m.citations or [],
            "created_at": m.created_at,
        }
        for m in c.messages.history(session_id, limit=200)
    ]
    return {"session_id": session_id, "messages": messages}

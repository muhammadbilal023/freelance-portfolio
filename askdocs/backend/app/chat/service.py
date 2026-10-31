"""Chat orchestration: prepare a RAG turn, then answer (blocking or streaming).

Everything route-specific (validation, SSE encoding) stays out of here so the
guardrail logic can be unit-tested against the FakeLLM without an HTTP layer.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

from app.guardrails import prompt as guard
from app.guardrails import sanitize
from app.rag.citations import build_context
from app.rag.retriever import retrieve

if TYPE_CHECKING:
    from app.main import Container

HISTORY_TURNS = 10  # prior messages (both roles) included for conversational context


@dataclass
class PreparedTurn:
    session_id: str
    user_message_id: int
    system_prompt: str
    messages: list[dict[str, str]]
    citations: list[dict[str, Any]] = field(default_factory=list)
    has_context: bool = False
    needs_human: bool = False


@dataclass
class Answer:
    text: str
    citations: list[dict[str, Any]]
    message_id: int
    needs_handoff: bool


def new_session_id() -> str:
    return uuid.uuid4().hex


async def prepare_turn(
    container: Container, user_id: str, session_id: str, question: str
) -> PreparedTurn:
    clean_question = sanitize.sanitize_user_message(question)
    if session_id and container.sessions.get(session_id) is None:
        container.sessions.create(session_id, user_id)
    elif not session_id:
        session_id = new_session_id()
        container.sessions.create(session_id, user_id)

    # History BEFORE storing the current question (so it isn't duplicated).
    history = container.messages.history(session_id, limit=HISTORY_TURNS)

    retrieved = await _retrieve(container, clean_question)
    context, citations = build_context(retrieved)
    has_context = bool(retrieved)

    user_message = container.messages.add(session_id, "user", clean_question)

    messages = [{"role": m.role, "content": m.content} for m in history]
    messages.append({"role": "user", "content": clean_question})

    return PreparedTurn(
        session_id=session_id,
        user_message_id=user_message.id,
        system_prompt=guard.build_system_prompt(context),
        messages=messages,
        citations=citations,
        has_context=has_context,
        needs_human=guard.wants_human(clean_question),
    )


async def _retrieve(container: Container, question: str):
    from fastapi.concurrency import run_in_threadpool

    s = container.settings
    return await run_in_threadpool(
        lambda: retrieve(
            vectors=container.vectors,
            documents=container.documents,
            embedder=container.embedder,
            query=question,
            top_k=s.retrieval_top_k,
            min_score=s.retrieval_min_score,
            chunks_repo=container.chunks,
        )
    )


def _referenced_citations(
    answer_text: str, citations: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    return [c for c in citations if f"[S{c['id']}]" in answer_text]


async def answer_blocking(container: Container, prepared: PreparedTurn) -> Answer:
    """Non-streaming answer with strict grounding: ungrounded -> fallback."""
    if not prepared.has_context:
        text, used, needs_handoff, tokens = guard.FALLBACK_ANSWER, [], True, (0, 0)
    else:
        result = await container.llm.complete(prepared.system_prompt, prepared.messages)
        tokens = (result.prompt_tokens, result.completion_tokens)
        if guard.is_fallback(result.text):
            text, used, needs_handoff = guard.FALLBACK_ANSWER, [], True
        elif _referenced_citations(result.text, prepared.citations):
            text = result.text
            used = _referenced_citations(result.text, prepared.citations)
            needs_handoff = prepared.needs_human
        else:
            # Answered but cited nothing -> refuse to pass it off as grounded.
            text, used, needs_handoff = guard.FALLBACK_ANSWER, [], True

    stored = container.messages.add(
        prepared.session_id,
        "assistant",
        text,
        citations=used,
        prompt_tokens=tokens[0],
        completion_tokens=tokens[1],
    )
    if needs_handoff:
        container.messages.mark_handoff(stored.id)
    return Answer(text=text, citations=used, message_id=stored.id, needs_handoff=needs_handoff)


async def stream_answer(container: Container, prepared: PreparedTurn):
    """Yield (event, data) tuples; persists the assistant message at the end.

    Streaming can't retract a token already sent, so instead of forcing the
    fallback it flags `ungrounded` in the terminal `done` event for the UI.
    """
    if not prepared.has_context:
        yield ("citations", [])
        yield ("token", {"text": guard.FALLBACK_ANSWER})
        stored = container.messages.add(prepared.session_id, "assistant", guard.FALLBACK_ANSWER)
        container.messages.mark_handoff(stored.id)
        yield ("done", {"message_id": stored.id, "needs_handoff": True, "citations": []})
        return

    yield ("citations", prepared.citations)
    parts: list[str] = []
    async for delta in container.llm.stream(prepared.system_prompt, prepared.messages):
        parts.append(delta)
        yield ("token", {"text": delta})
    text = "".join(parts).strip()

    if guard.is_fallback(text):
        used, needs_handoff = [], True
    else:
        used = _referenced_citations(text, prepared.citations)
        grounded = bool(used)
        needs_handoff = prepared.needs_human or not grounded

    stored = container.messages.add(
        prepared.session_id, "assistant", text, citations=used, prompt_tokens=0, completion_tokens=0
    )
    if needs_handoff:
        container.messages.mark_handoff(stored.id)
    yield (
        "done",
        {
            "message_id": stored.id,
            "needs_handoff": needs_handoff,
            "citations": used,
            "ungrounded": bool(text) and not used and not guard.is_fallback(text),
        },
    )

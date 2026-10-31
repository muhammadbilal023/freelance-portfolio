"""Conversation summarization for the support ticket (LLM-assisted, safe fallback)."""

from __future__ import annotations

import json
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from app.db.repositories import Message
    from app.llm.base import LLMProvider

_SUMMARY_SYSTEM = (
    "You summarize customer-support conversations so a human agent can take over.\n"
    "Respond with ONLY a JSON object with keys: issue (what the customer wants), "
    "attempted (what the bot already tried), urgency (low | normal | high).\n"
    "No prose, no code fences."
)


async def build_summary(
    llm: LLMProvider, transcript: list[Message], last_question: str, reason: str
) -> dict[str, Any]:
    lines = [f"{m.role}: {m.content}" for m in transcript][-12:]
    user_prompt = f"Handoff reason: {reason}\nConversation:\n" + "\n".join(lines)
    try:
        result = await llm.complete(_SUMMARY_SYSTEM, [{"role": "user", "content": user_prompt}])
        parsed = _extract_json(result.text)
    except Exception:  # noqa: BLE001 - summarization must never block a handoff
        parsed = None
    if not parsed:
        parsed = _heuristic(last_question, reason)
    parsed["reason"] = reason
    parsed["turns"] = len(transcript)
    return parsed


def _extract_json(text: str) -> dict[str, Any] | None:
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return None
    try:
        obj = json.loads(text[start : end + 1])
    except json.JSONDecodeError:
        return None
    if not isinstance(obj, dict):
        return None
    return {
        "issue": str(obj.get("issue", ""))[:500],
        "attempted": str(obj.get("attempted", ""))[:500],
        "urgency": _normalize_urgency(obj.get("urgency")),
    }


def _heuristic(question: str, reason: str) -> dict[str, Any]:
    return {
        "issue": question[:500] or "Customer requested help",
        "attempted": f"Assistant {reason.replace('_', ' ')}; no grounded answer available.",
        "urgency": _normalize_urgency(None),
    }


def _normalize_urgency(value: object) -> str:
    v = str(value).lower().strip()
    return v if v in ("low", "normal", "high") else "normal"

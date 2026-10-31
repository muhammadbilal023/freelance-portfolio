"""Chat endpoints over HTTP: grounded answers, fallbacks, SSE streaming, feedback."""

from __future__ import annotations

import json

from app.llm.fake import FakeLLM
from fastapi.testclient import TestClient
from tests.conftest import upload_text


def _post_chat(client: TestClient, question: str, session_id: str = "") -> dict:
    res = client.post(
        "/chat",
        json={"question": question, "session_id": session_id},
        headers={"X-User-Id": "tester"},
    )
    assert res.status_code == 200, res.text
    return res.json()


def test_grounded_answer_returns_citations(client: TestClient, fake_llm: FakeLLM) -> None:
    fake_llm.resolver = lambda system, messages: "Refunds are processed in five days [S1]."
    upload_text(client, "returns.txt", "Refunds are processed within five business days.")
    body = _post_chat(client, "How long for a refund?")
    assert "[S1]" in body["answer"]
    assert body["needs_handoff"] is False
    assert body["citations"] and body["citations"][0]["file_name"] == "returns.txt"


def test_no_documents_falls_back_and_requests_handoff(client: TestClient) -> None:
    body = _post_chat(client, "What is the policy on unicorns?")
    assert body["answer"] == "I don't know."
    assert body["needs_handoff"] is True
    assert body["handoff_job_id"] is not None


def test_explicit_human_request_triggers_handoff(client: TestClient, fake_llm: FakeLLM) -> None:
    fake_llm.resolver = lambda system, messages: "Let me connect you [S1]."
    upload_text(client, "hours.txt", "We are open weekdays from nine to five.")
    body = _post_chat(client, "I want to talk to a human, please")
    assert body["needs_handoff"] is True  # wants_human -> handoff even when grounded


def test_session_history_is_continuous(client: TestClient, fake_llm: FakeLLM) -> None:
    fake_llm.resolver = lambda system, messages: "We ship on weekdays [S1]."
    upload_text(client, "shipping.txt", "We ship orders on weekdays via courier.")
    first = _post_chat(client, "Do you ship?")
    sid = first["session_id"]
    _post_chat(client, "And on weekends?", session_id=sid)
    hist = client.get(f"/chat/sessions/{sid}/messages", headers={"X-User-Id": "tester"}).json()
    # 2 user + 2 assistant messages, oldest-first.
    assert len(hist["messages"]) == 4
    assert [m["role"] for m in hist["messages"]] == ["user", "assistant", "user", "assistant"]


def test_stream_emits_session_then_tokens_then_done(client: TestClient, fake_llm: FakeLLM) -> None:
    fake_llm.resolver = lambda system, messages: "Refunds take five business days [S1]."
    upload_text(client, "returns.txt", "Refunds are processed within five business days.")
    with client.stream(
        "POST",
        "/chat/stream",
        json={"question": "How long for refunds?", "session_id": ""},
        headers={"X-User-Id": "tester", "Content-Type": "application/json"},
    ) as resp:
        assert resp.status_code == 200
        assert resp.headers["content-type"].startswith("text/event-stream")
        raw = "".join(resp.iter_text())

    events = [
        line.split("event: ", 1)[1].strip()
        for line in raw.splitlines()
        if line.startswith("event: ")
    ]
    assert events[0] == "session"
    assert "token" in events
    assert events[-1] == "done"
    assert events.index("citations") < events.index("done")

    # Reassemble the streamed tokens; they must reconstruct the full answer.
    tokens = []
    for block in raw.split("\n\n"):
        lines = block.splitlines()
        if len(lines) >= 2 and lines[0] == "event: token":
            tokens.append(json.loads(lines[1][len("data: ") :])["text"])
    assert "".join(tokens).strip() == "Refunds take five business days [S1]."


def test_feedback_is_recorded(client: TestClient, fake_llm: FakeLLM) -> None:
    fake_llm.resolver = lambda system, messages: "We are open weekdays [S1]."
    upload_text(client, "hours.txt", "We are open weekdays from nine to five.")
    body = _post_chat(client, "Opening hours?")
    res = client.post(
        "/feedback",
        json={"message_id": body["message_id"], "rating": "helpful"},
        headers={"X-User-Id": "tester"},
    )
    assert res.status_code == 200
    assert res.json()["recorded"] is True


def test_feedback_on_missing_message_is_404(client: TestClient) -> None:
    res = client.post(
        "/feedback",
        json={"message_id": 999999, "rating": "helpful"},
        headers={"X-User-Id": "tester"},
    )
    assert res.status_code == 404
    assert res.json()["error"]["code"] == "not_found"

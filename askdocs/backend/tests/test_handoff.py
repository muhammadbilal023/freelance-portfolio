"""Human-handoff workflow: enqueue -> deliver, idempotency, dead-letters, admin."""

from __future__ import annotations

from app.config import Settings
from app.db.database import open_database
from app.handoff.handoff import HANDOFF_JOB, enqueue_handoff
from app.llm.fake import FakeLLM
from app.main import Container, create_app
from fastapi.testclient import TestClient
from tests.conftest import RecordingNotifier, RecordingTicket


def _build(settings: Settings, ticket: RecordingTicket, notifier: RecordingNotifier):
    conn, _vec = open_database(":memory:", settings.embedding_dimensions)
    app = create_app(
        settings,
        conn=conn,
        llm=FakeLLM(dimensions=settings.embedding_dimensions),
        ticket_client=ticket,
        notifier=notifier,
    )
    return app


def _session_with_message(container: Container, sid: str = "s1") -> int:
    container.sessions.create(sid, "u1")
    container.messages.add(sid, "user", "I need help")
    msg = container.messages.add(sid, "assistant", "I don't know.")
    return msg.id


async def test_handoff_delivers_ticket_and_notification(settings: Settings) -> None:
    ticket = RecordingTicket()
    notifier = RecordingNotifier()
    app = _build(settings, ticket, notifier)
    c = app.state.container
    trigger_id = _session_with_message(c)
    job_id = await enqueue_handoff(
        c, session_id="s1", trigger_message_id=trigger_id, reason="model_fallback"
    )
    assert job_id is not None
    assert c.jobs.get(job_id).type == HANDOFF_JOB
    assert c.runner.drain() == 1
    assert c.jobs.get(job_id).status == "succeeded"
    assert len(ticket.calls) == 1
    fields = ticket.calls[0]
    assert fields["Reason"] == "model_fallback"
    assert fields["Status"] == "Open"
    assert "Urgency" in fields and fields["Urgency"] in ("low", "normal", "high")
    assert len(notifier.messages) == 1


async def test_handoff_is_idempotent_per_trigger_message(settings: Settings) -> None:
    app = _build(settings, RecordingTicket(), RecordingNotifier())
    c = app.state.container
    trigger_id = _session_with_message(c)
    first = await enqueue_handoff(c, session_id="s1", trigger_message_id=trigger_id, reason="x")
    second = await enqueue_handoff(c, session_id="s1", trigger_message_id=trigger_id, reason="x")
    assert first is not None
    assert second is None  # same (session, message) -> no duplicate ticket


async def test_unconfigured_airtable_dead_letters_the_job(settings: Settings) -> None:
    # Default Airtable client with no credentials -> ConfigError -> dead-letter.
    conn, _vec = open_database(":memory:", settings.embedding_dimensions)
    app = create_app(settings, conn=conn, llm=FakeLLM(dimensions=settings.embedding_dimensions))
    c = app.state.container
    trigger_id = _session_with_message(c)
    job_id = await enqueue_handoff(c, session_id="s1", trigger_message_id=trigger_id, reason="x")
    assert c.runner.drain() == 1
    assert c.jobs.get(job_id).status == "dead"
    assert "Airtable" in c.jobs.get(job_id).last_error
    assert len(c.dead_letters.list_recent()) == 1


def test_negative_feedback_streak_escalates(settings: Settings) -> None:
    ticket = RecordingTicket()
    app = _build(settings, ticket, RecordingNotifier())
    headers = {"X-User-Id": "u9"}
    with TestClient(app) as client:
        c = app.state.container
        c.sessions.create("fs", "u9")
        m1 = c.messages.add("fs", "assistant", "answer one")
        m2 = c.messages.add("fs", "assistant", "answer two")

        fb1 = client.post(
            "/feedback", json={"message_id": m1.id, "rating": "not_helpful"}, headers=headers
        )
        assert fb1.json()["handoff_job_id"] is None  # below threshold
        fb2 = client.post(
            "/feedback", json={"message_id": m2.id, "rating": "not_helpful"}, headers=headers
        )
        assert fb2.json()["handoff_job_id"] is not None  # threshold crossed

        assert c.runner.drain() == 1
        assert ticket.calls[0]["Reason"] == "negative_feedback"

        # A third negative is above the threshold and must not open another ticket.
        m3 = c.messages.add("fs", "assistant", "answer three")
        fb3 = client.post(
            "/feedback", json={"message_id": m3.id, "rating": "not_helpful"}, headers=headers
        )
        assert fb3.json()["handoff_job_id"] is None


def test_admin_escalate_and_summary_endpoints(settings: Settings) -> None:
    ticket = RecordingTicket()
    app = _build(settings, ticket, RecordingNotifier())
    headers = {"X-User-Id": "u5"}
    with TestClient(app) as client:
        c = app.state.container
        _session_with_message(c, "admin-sess")

        esc = client.post("/admin/api/sessions/admin-sess/handoff", headers=headers)
        assert esc.status_code == 200
        assert esc.json()["queued"] is True
        assert esc.json()["jobType"] == HANDOFF_JOB

        # Escalating the same last-assistant message again is a no-op.
        esc2 = client.post("/admin/api/sessions/admin-sess/handoff", headers=headers)
        assert esc2.json()["queued"] is False

        client.get("/admin/api/jobs")
        client.get("/admin/api/events")
        summ = client.get("/admin/api/summary").json()
        assert "jobs" in summ and "documents" in summ

        assert c.runner.drain() == 1
        assert len(ticket.calls) == 1


async def test_admin_dead_letter_retry_reenqueues(settings: Settings) -> None:
    # Unconfigured delivery -> dead letter -> manual retry makes a fresh job.
    conn, _vec = open_database(":memory:", settings.embedding_dimensions)
    app = create_app(settings, conn=conn, llm=FakeLLM(dimensions=settings.embedding_dimensions))
    headers = {"X-User-Id": "u7"}
    with TestClient(app) as client:
        c = app.state.container
        trigger_id = _session_with_message(c)
        job_id = await enqueue_handoff(
            c, session_id="s1", trigger_message_id=trigger_id, reason="x"
        )
        c.runner.drain()
        assert c.jobs.get(job_id).status == "dead"
        dl = c.dead_letters.list_recent()[0]

        res = client.post(f"/admin/api/dead-letters/{dl['id']}/retry", headers=headers)
        assert res.status_code == 200
        new_job_id = res.json()["jobId"]
        assert new_job_id != job_id
        assert c.jobs.get(new_job_id).status == "queued"
        # The dead-letter row is stamped as retried.
        assert c.dead_letters.get(dl["id"])["retried_at"] is not None

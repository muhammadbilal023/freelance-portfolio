"""Shared pytest fixtures: an app wired to an in-memory DB + fake LLM."""

from __future__ import annotations

import pytest
from app.config import Settings
from app.db.database import open_database
from app.handoff.types import Notifier, TicketClient
from app.llm.fake import FakeLLM
from app.main import create_app
from fastapi.testclient import TestClient


class RecordingTicket(TicketClient):
    """Fake ticket store; optionally raises to exercise retry/dead-letter paths."""

    def __init__(self, error: Exception | None = None) -> None:
        self.calls: list[dict] = []
        self._error = error

    def create_ticket(self, fields: dict) -> str:
        if self._error is not None:
            raise self._error
        self.calls.append(fields)
        return "https://airtable.example/ticket/1"


class RecordingNotifier(Notifier):
    def __init__(self) -> None:
        self.messages: list[str] = []

    def notify(self, text: str) -> None:
        self.messages.append(text)


@pytest.fixture
def settings() -> Settings:
    return Settings(
        database_path=":memory:",
        llm_provider="fake",
        log_level="ERROR",
        openai_api_key="",
        anthropic_api_key="",
        retrieval_min_score=0.30,
        handoff_neg_feedback_threshold=2,
    )


@pytest.fixture
def fake_llm(settings: Settings) -> FakeLLM:
    return FakeLLM(dimensions=settings.embedding_dimensions)


@pytest.fixture
def container(settings: Settings, fake_llm: FakeLLM):
    """The raw container for unit tests that call services/repositories directly."""
    conn, _vec = open_database(":memory:", settings.embedding_dimensions)
    app = create_app(
        settings,
        conn=conn,
        llm=fake_llm,
        ticket_client=RecordingTicket(),
        notifier=RecordingNotifier(),
    )
    return app.state.container


@pytest.fixture
def client(settings: Settings, fake_llm: FakeLLM):
    conn, _vec = open_database(":memory:", settings.embedding_dimensions)
    app = create_app(
        settings,
        conn=conn,
        llm=fake_llm,
        ticket_client=RecordingTicket(),
        notifier=RecordingNotifier(),
    )
    with TestClient(app) as test_client:
        yield test_client


def upload_text(client: TestClient, file_name: str, text: str) -> dict:
    """Helper: ingest a plain-text document through the real endpoint."""
    res = client.post(
        "/documents/upload",
        files={"file": (file_name, text.encode("utf-8"), "text/plain")},
        headers={"X-User-Id": "tester"},
    )
    assert res.status_code == 201, res.text
    return res.json()

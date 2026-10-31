"""Application factory + dependency container (the composition root).

Everything the routes need lives on `app.state.container`; tests build the same
app with overrides (settings, in-memory db, fake LLM) and nothing else changes.
"""

from __future__ import annotations

import logging
import sqlite3
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app.config import Settings, get_settings
from app.db.database import is_vec_available, open_database
from app.db.repositories import (
    ChunksRepository,
    DeadLettersRepository,
    DocumentsRepository,
    FeedbackRepository,
    JobsRepository,
    MessagesRepository,
    SessionsRepository,
    VectorStore,
    WebhookEventsRepository,
)
from app.errors import ConfigError, register_exception_handlers
from app.handoff.airtable_client import AirtableTicketClient
from app.handoff.handoff import HANDOFF_JOB, make_handler
from app.handoff.slack_client import SlackNotifier
from app.handoff.types import Notifier, TicketClient
from app.llm.base import Embedder, LLMProvider
from app.llm.fake import FakeLLM
from app.logging_setup import register_secrets, setup_logging
from app.queue.backoff import BackoffOptions
from app.queue.job_runner import JobRunner
from app.rate_limit import TokenBucketLimiter
from app.routes import admin, chat, documents, feedback, health


@dataclass
class Container:
    settings: Settings
    logger: logging.Logger
    conn: sqlite3.Connection
    documents: DocumentsRepository
    chunks: ChunksRepository
    vectors: VectorStore
    sessions: SessionsRepository
    messages: MessagesRepository
    feedback: FeedbackRepository
    jobs: JobsRepository
    dead_letters: DeadLettersRepository
    events: WebhookEventsRepository
    llm: LLMProvider
    embedder: Embedder
    limiter: TokenBucketLimiter
    ticket_client: TicketClient
    notifier: Notifier
    runner: JobRunner | None = None
    extras: dict[str, object] = field(default_factory=dict)  # modules added in later milestones


def build_chat(settings: Settings, logger: logging.Logger) -> LLMProvider:
    """Chat provider factory.

    Missing credentials degrade to the deterministic FakeLLM (with a warning) so
    the service always boots - same 'optional until used' philosophy as SyncFlow.
    """
    if settings.llm_provider == "fake":
        return FakeLLM(dimensions=settings.embedding_dimensions)
    if settings.llm_provider == "openai":
        if not settings.openai_api_key:
            logger.warning("OPENAI_API_KEY missing; falling back to fake chat")
            return FakeLLM(dimensions=settings.embedding_dimensions)
        from app.llm.openai_provider import OpenAIProvider

        return OpenAIProvider(settings)
    if settings.llm_provider == "anthropic":
        if not settings.anthropic_api_key:
            logger.warning("ANTHROPIC_API_KEY missing; falling back to fake chat")
            return FakeLLM(dimensions=settings.embedding_dimensions)
        from app.llm.anthropic_provider import AnthropicProvider

        return AnthropicProvider(settings)
    raise ConfigError(f"unknown LLM provider {settings.llm_provider}")


def build_embedder(settings: Settings, logger: logging.Logger) -> Embedder:
    """Embeddings always want OpenAI; without a key fall back to the fake hash
    embedder so ingestion + retrieval still work offline (values are not
    comparable to real OpenAI vectors, but the pipeline is exercised end-to-end).
    """
    if settings.openai_api_key:
        from app.llm.openai_provider import OpenAIProvider

        return OpenAIProvider(settings)
    logger.warning("OPENAI_API_KEY missing; using deterministic fake embedder")
    return FakeLLM(dimensions=settings.embedding_dimensions)


def create_app(
    settings: Settings | None = None,
    *,
    conn: sqlite3.Connection | None = None,
    llm: LLMProvider | None = None,
    embedder: Embedder | None = None,
    ticket_client: TicketClient | None = None,
    notifier: Notifier | None = None,
    start_runner: bool = False,
) -> FastAPI:
    cfg = settings or get_settings()
    logger = setup_logging(cfg.log_level, pretty=cfg.log_pretty)
    if conn is None:
        database, vec_available = open_database(cfg.database_path, cfg.embedding_dimensions)
    else:
        database = conn
        vec_available = is_vec_available(database)

    container = Container(
        settings=cfg,
        logger=logger,
        conn=database,
        documents=DocumentsRepository(database),
        chunks=ChunksRepository(database),
        vectors=VectorStore(database, vec_available=vec_available),
        sessions=SessionsRepository(database),
        messages=MessagesRepository(database),
        feedback=FeedbackRepository(database),
        jobs=JobsRepository(database),
        dead_letters=DeadLettersRepository(database),
        events=WebhookEventsRepository(database),
        llm=llm or build_chat(cfg, logger),
        embedder=embedder or (llm if isinstance(llm, Embedder) else build_embedder(cfg, logger)),
        limiter=TokenBucketLimiter(cfg.rate_limit_capacity, cfg.rate_limit_refill_per_sec),
        ticket_client=ticket_client or AirtableTicketClient(cfg),
        notifier=notifier or SlackNotifier(cfg),
    )

    # The runner needs the container (handlers are bound to it), and the container
    # exposes the runner to routes - so build the container first, then attach.
    registry = {HANDOFF_JOB: make_handler(container)}
    runner = JobRunner(
        jobs=container.jobs,
        dead_letters=container.dead_letters,
        registry=registry,
        backoff=BackoffOptions(base_ms=cfg.backoff_base_ms, max_ms=cfg.backoff_max_ms),
        poll_interval_ms=cfg.job_poll_interval_ms,
        logger=logger,
    )
    container.runner = runner

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        register_secrets(
            logger,
            [
                cfg.openai_api_key,
                cfg.anthropic_api_key,
                cfg.airtable_api_key,
                cfg.slack_webhook_url,
            ],
        )
        # Off by default so tests import/boot stay deterministic; Docker enables it.
        if start_runner:
            runner.start()
        try:
            yield
        finally:
            if start_runner:
                runner.stop()

    app = FastAPI(title="AskDocs", version="1.0.0", lifespan=lifespan)
    app.state.container = container
    register_exception_handlers(app)
    # The chat web UI calls the API from file:// or any host in development.
    app.add_middleware(
        CORSMiddleware, allow_origins=["*"], allow_headers=["*"], allow_methods=["*"]
    )
    app.include_router(health.router)
    app.include_router(documents.router)
    app.include_router(chat.router)
    app.include_router(feedback.router)
    app.include_router(admin.router)

    admin_dir = Path(__file__).resolve().parent.parent / "admin"
    if admin_dir.is_dir():  # appears in milestone A5
        app.mount("/", StaticFiles(directory=str(admin_dir), html=True), name="admin")

    return app


def __getattr__(name: str):  # PEP 562: lazy ASGI app for `uvicorn app.main:app`
    # Building the app at import time would open the default on-disk database
    # (and warn about keys) whenever anything merely imports create_app - e.g. tests.
    if name == "app":
        app = create_app(start_runner=True)
        globals()["app"] = app
        return app
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")

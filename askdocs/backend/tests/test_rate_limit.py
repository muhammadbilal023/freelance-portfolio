"""Rate limiting: token-bucket math + HTTP 429 with Retry-After."""

from __future__ import annotations

from app.config import Settings
from app.db.database import open_database
from app.llm.fake import FakeLLM
from app.main import create_app
from app.rate_limit import TokenBucketLimiter
from fastapi.testclient import TestClient


def test_bucket_denies_after_capacity_exhausted() -> None:
    limiter = TokenBucketLimiter(capacity=3, refill_per_sec=0.001)
    assert limiter.try_acquire("u")[0] is True
    assert limiter.try_acquire("u")[0] is True
    assert limiter.try_acquire("u")[0] is True
    allowed, retry_after = limiter.try_acquire("u")
    assert allowed is False
    assert retry_after > 0


def test_buckets_are_isolated_per_user() -> None:
    limiter = TokenBucketLimiter(capacity=1, refill_per_sec=0.001)
    assert limiter.try_acquire("alice")[0] is True
    assert limiter.try_acquire("alice")[0] is False
    # A different user still has a full bucket.
    assert limiter.try_acquire("bob")[0] is True


def _rate_limited_client() -> TestClient:
    settings = Settings(
        database_path=":memory:",
        llm_provider="fake",
        log_level="ERROR",
        openai_api_key="",
        anthropic_api_key="",
        rate_limit_capacity=2,
        rate_limit_refill_per_sec=0.001,
    )
    conn, _vec = open_database(":memory:", settings.embedding_dimensions)
    app = create_app(settings, conn=conn, llm=FakeLLM(dimensions=settings.embedding_dimensions))
    return TestClient(app)


def test_chat_returns_429_when_rate_exceeded() -> None:
    with _rate_limited_client() as client:
        headers = {"X-User-Id": "burst-user"}
        assert client.post("/chat", json={"question": "a"}, headers=headers).status_code == 200
        assert client.post("/chat", json={"question": "b"}, headers=headers).status_code == 200
        res = client.post("/chat", json={"question": "c"}, headers=headers)
        assert res.status_code == 429
        assert res.json()["error"]["code"] == "rate_limited"
        assert int(res.headers["Retry-After"]) >= 1

"""Job queue: backoff math + runner retry / dead-letter / rate-limit semantics."""

from __future__ import annotations

import time

import pytest
from app.errors import ConfigError, RateLimitError
from app.main import Container
from app.queue.backoff import BackoffOptions, compute_backoff_ms
from app.queue.job_runner import JobRunner, NonRetryableJobError


def _now_ms() -> int:
    return int(time.time() * 1000)


def _runner(container: Container, registry: dict) -> JobRunner:
    return JobRunner(
        jobs=container.jobs,
        dead_letters=container.dead_letters,
        registry=registry,
        backoff=BackoffOptions(base_ms=1, max_ms=10),
        poll_interval_ms=50,
        logger=container.logger,
        random_fn=lambda: 0.0,
    )


# ----------------------------- backoff math ---------------------------------


def test_backoff_equal_jitter_bounds() -> None:
    opts = BackoffOptions(base_ms=1000, max_ms=100_000)
    assert compute_backoff_ms(1, opts, lambda: 0.0) == 500  # half fixed + 0 jitter
    assert compute_backoff_ms(1, opts, lambda: 1.0) == 1000  # half + full jitter half
    assert compute_backoff_ms(2, opts, lambda: 0.0) == 1000  # doubles


def test_backoff_caps_at_max() -> None:
    opts = BackoffOptions(base_ms=1000, max_ms=1500)
    assert compute_backoff_ms(10, opts, lambda: 1.0) <= 1500


def test_backoff_rejects_bad_attempt() -> None:
    with pytest.raises(ValueError):
        compute_backoff_ms(0, BackoffOptions(base_ms=10, max_ms=100))


# ----------------------------- runner paths ---------------------------------


def test_successful_job_is_marked_succeeded(container: Container) -> None:
    seen: list[dict] = []
    runner = _runner(container, {"t.ok": lambda p: seen.append(p)})
    job_id = container.jobs.enqueue("t.ok", {"x": 1}, max_attempts=3)
    assert runner.drain() == 1
    assert container.jobs.get(job_id).status == "succeeded"
    assert seen == [{"x": 1}]


def test_retryable_failure_requeues_with_backoff(container: Container) -> None:
    calls = {"n": 0}

    def flaky(payload: dict) -> None:
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("transient")

    runner = _runner(container, {"t.flaky": flaky})
    job_id = container.jobs.enqueue("t.flaky", {}, max_attempts=5)
    before = _now_ms()
    assert runner.poll_once() is True
    job = container.jobs.get(job_id)
    assert job.status == "queued"
    assert job.attempts == 1
    assert job.next_retry_at >= before
    # Second poll runs after the (sub-millisecond) backoff and succeeds.
    assert runner.drain() == 1
    assert container.jobs.get(job_id).status == "succeeded"


def test_attempts_exhausted_dead_letters(container: Container) -> None:
    def always_fail(payload: dict) -> None:
        raise RuntimeError("boom")

    runner = _runner(container, {"t.bad": always_fail})
    job_id = container.jobs.enqueue("t.bad", {}, max_attempts=1)
    assert runner.drain() == 1
    assert container.jobs.get(job_id).status == "dead"
    dls = container.dead_letters.list_recent()
    assert len(dls) == 1
    assert dls[0]["type"] == "t.bad"


def test_non_retryable_error_dead_letters_immediately(container: Container) -> None:
    def nope(payload: dict) -> None:
        raise NonRetryableJobError("bad payload")

    runner = _runner(container, {"t.hard": nope})
    job_id = container.jobs.enqueue("t.hard", {}, max_attempts=5)
    runner.drain()
    assert container.jobs.get(job_id).status == "dead"


def test_config_error_dead_letters_immediately(container: Container) -> None:
    def unconfigured(payload: dict) -> None:
        raise ConfigError("Airtable")

    runner = _runner(container, {"t.cfg": unconfigured})
    job_id = container.jobs.enqueue("t.cfg", {}, max_attempts=5)
    runner.drain()
    job = container.jobs.get(job_id)
    assert job.status == "dead"
    assert "Airtable" in job.last_error


def test_rate_limit_error_honors_retry_after(container: Container) -> None:
    def throttled(payload: dict) -> None:
        raise RateLimitError(5)

    runner = _runner(container, {"t.rl": throttled})
    job_id = container.jobs.enqueue("t.rl", {}, max_attempts=5)
    before = _now_ms()
    runner.poll_once()
    job = container.jobs.get(job_id)
    assert job.status == "queued"
    # retry-after 5s => not due for ~5000ms
    assert job.next_retry_at - before >= 4900


def test_unknown_job_type_is_dead_lettered(container: Container) -> None:
    runner = _runner(container, {})  # empty registry
    job_id = container.jobs.enqueue("t.orphan", {}, max_attempts=3)
    runner.drain()
    assert container.jobs.get(job_id).status == "dead"

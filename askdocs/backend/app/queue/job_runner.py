"""Polling job runner: claims due jobs, executes handlers, retries + dead-letters.

Same semantics SyncFlow uses: at-least-once execution via an atomic claim,
exponential backoff on retryable failures, a dead-letter copy when attempts run
out or a job is explicitly non-retryable. Handlers are synchronous (blocking
HTTP) and run either in the background thread or, in tests, one poll at a time.
"""

from __future__ import annotations

import logging
import random
import threading
import time
from collections.abc import Callable

from app.db.repositories import DeadLettersRepository, Job, JobsRepository
from app.errors import ConfigError, RateLimitError
from app.queue.backoff import BackoffOptions, compute_backoff_ms

JobHandler = Callable[[dict], None]


class NonRetryableJobError(Exception):
    """Raised by a handler when retrying is pointless (bad payload, permanent error)."""


def _now_ms() -> int:
    return int(time.time() * 1000)


class JobRunner:
    def __init__(
        self,
        *,
        jobs: JobsRepository,
        dead_letters: DeadLettersRepository,
        registry: dict[str, JobHandler],
        backoff: BackoffOptions,
        poll_interval_ms: int,
        logger: logging.Logger,
        random_fn: Callable[[], float] = random.random,
    ):
        self._jobs = jobs
        self._dead = dead_letters
        self._registry = registry
        self._backoff = backoff
        self._poll_ms = poll_interval_ms
        self._logger = logger
        self._random = random_fn
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="askdocs-job-runner", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None

    def _loop(self) -> None:
        while not self._stop.is_set():
            processed = self.poll_once()
            if not processed:
                self._stop.wait(self._poll_ms / 1000)

    def poll_once(self) -> bool:
        """Process a single due job; True if one was claimed."""
        job = self._jobs.claim_next_due()
        if job is None:
            return False
        self._process(job)
        return True

    def drain(self, max_jobs: int = 1000) -> int:
        """Process every currently-due job (test helper). Returns count."""
        count = 0
        while count < max_jobs and self.poll_once():
            count += 1
        return count

    def _process(self, job: Job) -> None:
        handler = self._registry.get(job.type)
        if handler is None:
            self._kill(job, f"no handler registered for job type '{job.type}'")
            return
        try:
            handler(job.payload)
        except (NonRetryableJobError, ConfigError) as exc:
            self._kill(job, str(exc))
        except RateLimitError as exc:
            self._retry(job, str(exc), honor_ms=int(exc.retry_after_seconds * 1000))
        except Exception as exc:  # noqa: BLE001 - any handler error is retryable
            self._retry(job, f"{type(exc).__name__}: {exc}", honor_ms=0)
        else:
            self._jobs.mark_succeeded(job.id)
            self._logger.info(
                "job succeeded", extra={"extras": {"job_id": job.id, "type": job.type}}
            )

    def _retry(self, job: Job, error: str, *, honor_ms: int) -> None:
        next_attempt = job.attempts + 1
        if next_attempt >= job.max_attempts:
            self._kill(job, error)
            return
        delay = compute_backoff_ms(next_attempt, self._backoff, self._random)
        delay = max(delay, honor_ms)
        self._jobs.requeue_for_retry(job.id, error, _now_ms() + delay)
        self._logger.warning(
            "job failed, retrying",
            extra={"extras": {"job_id": job.id, "attempt": next_attempt, "delay_ms": delay}},
        )

    def _kill(self, job: Job, error: str) -> None:
        self._jobs.mark_dead(job.id, error)
        self._dead.insert(job, error)
        self._logger.error(
            "job dead-lettered",
            extra={"extras": {"job_id": job.id, "type": job.type, "error": error}},
        )

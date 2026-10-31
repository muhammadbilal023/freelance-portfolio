"""In-process token-bucket rate limiting, keyed by user id.

Single-service scale by design: a dict of buckets is enough for one process.
At multi-instance scale this would move to Redis behind the same interface.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field


@dataclass
class _Bucket:
    capacity: float
    refill_per_sec: float
    tokens: float = field(init=False)
    last_refill: float = field(init=False)

    def __post_init__(self) -> None:
        self.tokens = self.capacity
        self.last_refill = time.monotonic()


class TokenBucketLimiter:
    def __init__(self, capacity: float, refill_per_sec: float):
        self._capacity = capacity
        self._refill = refill_per_sec
        self._buckets: dict[str, _Bucket] = {}
        self._lock = threading.Lock()

    def try_acquire(self, key: str) -> tuple[bool, float]:
        """Consume one token for `key`.

        Returns (allowed, retry_after_seconds). When denied, retry_after is how
        long until a token is available (never zero).
        """
        with self._lock:
            bucket = self._buckets.get(key)
            if bucket is None:
                bucket = _Bucket(self._capacity, self._refill)
                self._buckets[key] = bucket
            now = time.monotonic()
            bucket.tokens = min(
                self._capacity, bucket.tokens + (now - bucket.last_refill) * self._refill
            )
            bucket.last_refill = now
            if bucket.tokens >= 1.0:
                bucket.tokens -= 1.0
                return True, 0.0
            deficit = 1.0 - bucket.tokens
            return False, deficit / self._refill

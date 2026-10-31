"""Exponential backoff with equal jitter.

'Equal jitter' = half the computed delay is fixed, half is random. This keeps a
minimum delay (so we never hammer a provider) while spreading retries from many
jobs so they don't align into a thundering herd. `random` is injectable so the
math is deterministic in tests.
"""

from __future__ import annotations

import random
from collections.abc import Callable
from dataclasses import dataclass


@dataclass
class BackoffOptions:
    base_ms: int
    max_ms: int


def compute_backoff_ms(
    attempt: int, options: BackoffOptions, random_fn: Callable[[], float] = random.random
) -> int:
    if attempt < 1:
        raise ValueError("attempt must be >= 1")
    exponential = min(options.base_ms * (2 ** (attempt - 1)), options.max_ms)
    half = exponential / 2
    return round(half + half * random_fn())

"""Deterministic fake provider for tests and no-API-key demos.

Embeddings are bag-of-words hashed into the configured dimension and L2-normalized,
so cosine similarity behaves sensibly for overlapping vocabulary - real retrieval
ranking can be exercised without any API. Completions are produced by an
injectable resolver, so each test can assert exactly what the prompt contained.
"""

from __future__ import annotations

import math
import re
import zlib
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass, field

from app.llm.base import CompletionResult, Embedder, LLMProvider, approx_tokens

_WORD = re.compile(r"[a-z0-9']+")


@dataclass
class Call:
    kind: str  # 'complete' | 'stream'
    system: str
    messages: list[dict[str, str]]


@dataclass
class FakeLLM(LLMProvider, Embedder):
    dimensions: int = 256
    resolver: Callable[[str, list[dict[str, str]]], str] = field(
        default=lambda system, messages: "fake answer"
    )
    calls: list[Call] = field(default_factory=list)

    @property
    def name(self) -> str:
        return "fake"

    async def complete(
        self, system: str, messages: list[dict[str, str]], max_tokens: int | None = None
    ) -> CompletionResult:
        self.calls.append(Call("complete", system, messages))
        text = self.resolver(system, messages)
        prompt_text = system + "".join(m["content"] for m in messages)
        return CompletionResult(
            text=text,
            prompt_tokens=approx_tokens(prompt_text),
            completion_tokens=approx_tokens(text),
        )

    def stream(
        self, system: str, messages: list[dict[str, str]], max_tokens: int | None = None
    ) -> AsyncIterator[str]:
        self.calls.append(Call("stream", system, messages))
        return self._iter_words(self.resolver(system, messages))

    async def _iter_words(self, text: str) -> AsyncIterator[str]:
        words = text.split(" ")
        for i, word in enumerate(words):
            yield word if i == 0 else f" {word}"

    def embed(self, texts: list[str]) -> list[list[float]]:
        return [self._bow_vector(t) for t in texts]

    def _bow_vector(self, text: str) -> list[float]:
        vec = [0.0] * self.dimensions
        for word in _WORD.findall(text.lower()):
            # zlib.crc32 (not hash()) so vectors are stable across processes.
            vec[zlib.crc32(word.encode()) % self.dimensions] += 1.0
        norm = math.sqrt(sum(v * v for v in vec))
        if norm == 0:
            # Empty/stop-word-only text: a fixed unit vector, never strongly similar to content.
            vec[0] = 1.0
            return vec
        return [v / norm for v in vec]

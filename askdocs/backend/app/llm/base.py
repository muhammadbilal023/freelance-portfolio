"""Provider-agnostic LLM interfaces.

Two roles, because providers differ in capability:
  * LLMProvider - chat completion (complete/stream). Implemented by OpenAI,
    Anthropic, and the deterministic FakeLLM.
  * Embedder     - text -> vector. Always backed by OpenAI (Anthropic has no
    embedding API); when no OpenAI key is present the factory substitutes the
    FakeLLM's hashing embedder so the whole pipeline still runs offline.

`complete`/`stream` are async (HTTP is async); `embed` is sync over httpx.Client
because ingestion runs in a threadpool and returns whole batches at once.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import AsyncIterator
from dataclasses import dataclass


@dataclass
class CompletionResult:
    text: str
    prompt_tokens: int
    completion_tokens: int


class LLMProvider(ABC):
    @abstractmethod
    async def complete(
        self, system: str, messages: list[dict[str, str]], max_tokens: int | None = None
    ) -> CompletionResult:
        """One-shot completion. `messages` is a [{'role','content'}...] chat history."""

    @abstractmethod
    def stream(
        self, system: str, messages: list[dict[str, str]], max_tokens: int | None = None
    ) -> AsyncIterator[str]:
        """Token-delta stream of the same completion."""

    @property
    @abstractmethod
    def name(self) -> str: ...


class Embedder(ABC):
    @abstractmethod
    def embed(self, texts: list[str]) -> list[list[float]]:
        """Batch embeddings, dimension = configured embedding_dimensions."""

    @property
    @abstractmethod
    def name(self) -> str: ...


def approx_tokens(text: str) -> int:
    """Cheap token estimate (~4 chars/token) used by providers that don't echo usage."""
    return max(1, len(text) // 4)

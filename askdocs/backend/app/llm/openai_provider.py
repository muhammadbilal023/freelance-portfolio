"""OpenAI provider: chat completions, streaming, and embeddings over httpx.

Implements both roles (chat + embed) - it's the one provider that can do both,
which is why embeddings route here even when chat uses Anthropic.
"""

from __future__ import annotations

import json
from collections.abc import AsyncIterator

import httpx

from app.config import Settings
from app.errors import ApiError
from app.llm.base import CompletionResult, Embedder, LLMProvider

_BASE = "https://api.openai.com/v1"


class OpenAIProvider(LLMProvider, Embedder):
    def __init__(self, settings: Settings):
        self._s = settings
        self._headers = {"Authorization": f"Bearer {settings.openai_api_key}"}

    @property
    def name(self) -> str:
        return "openai"

    def _messages(self, system: str, messages: list[dict[str, str]]) -> list[dict[str, str]]:
        return [{"role": "system", "content": system}, *messages]

    async def complete(
        self, system: str, messages: list[dict[str, str]], max_tokens: int | None = None
    ) -> CompletionResult:
        payload = {
            "model": self._s.openai_chat_model,
            "messages": self._messages(system, messages),
            "max_tokens": max_tokens or self._s.llm_max_tokens,
        }
        async with httpx.AsyncClient(timeout=self._s.llm_timeout_seconds) as client:
            resp = await client.post(
                f"{_BASE}/chat/completions", headers=self._headers, json=payload
            )
        if resp.status_code != 200:
            raise ApiError.internal(f"OpenAI completion failed ({resp.status_code})")
        data = resp.json()
        usage = data.get("usage", {})
        return CompletionResult(
            text=data["choices"][0]["message"]["content"],
            prompt_tokens=int(usage.get("prompt_tokens", 0)),
            completion_tokens=int(usage.get("completion_tokens", 0)),
        )

    async def stream(
        self, system: str, messages: list[dict[str, str]], max_tokens: int | None = None
    ) -> AsyncIterator[str]:
        payload = {
            "model": self._s.openai_chat_model,
            "messages": self._messages(system, messages),
            "max_tokens": max_tokens or self._s.llm_max_tokens,
            "stream": True,
        }
        async with (
            httpx.AsyncClient(timeout=self._s.llm_timeout_seconds) as client,
            client.stream(
                "POST", f"{_BASE}/chat/completions", headers=self._headers, json=payload
            ) as resp,
        ):
            if resp.status_code != 200:
                raise ApiError.internal(f"OpenAI stream failed ({resp.status_code})")
            async for line in resp.aiter_lines():
                if not line.startswith("data:"):
                    continue
                chunk = line[len("data:") :].strip()
                if chunk == "[DONE]":
                    break
                delta = json.loads(chunk)["choices"][0].get("delta", {})
                content = delta.get("content")
                if content:
                    yield content

    def embed(self, texts: list[str]) -> list[list[float]]:
        payload = {
            "model": self._s.embedding_model,
            "input": texts,
            "dimensions": self._s.embedding_dimensions,
        }
        with httpx.Client(timeout=self._s.llm_timeout_seconds) as client:
            resp = client.post(f"{_BASE}/embeddings", headers=self._headers, json=payload)
        if resp.status_code != 200:
            raise ApiError.internal(f"OpenAI embedding failed ({resp.status_code})")
        data = resp.json()["data"]
        return [item["embedding"] for item in sorted(data, key=lambda d: d["index"])]

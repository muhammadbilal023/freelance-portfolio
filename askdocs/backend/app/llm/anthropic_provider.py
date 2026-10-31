"""Anthropic provider: chat completions + streaming over httpx.

Chat only - Anthropic has no embedding endpoint, so this class deliberately
does NOT implement Embedder (the factory pairs it with an OpenAI embedder).
"""

from __future__ import annotations

import json
from collections.abc import AsyncIterator

import httpx

from app.config import Settings
from app.errors import ApiError
from app.llm.base import CompletionResult, LLMProvider

_BASE = "https://api.anthropic.com/v1"
_VERSION = "2023-05-31"


class AnthropicProvider(LLMProvider):
    def __init__(self, settings: Settings):
        self._s = settings
        self._headers = {
            "x-api-key": settings.anthropic_api_key,
            "anthropic-version": _VERSION,
            "content-type": "application/json",
        }

    @property
    def name(self) -> str:
        return "anthropic"

    def _payload(
        self, system: str, messages: list[dict[str, str]], max_tokens: int | None
    ) -> dict[str, object]:
        return {
            "model": self._s.anthropic_chat_model,
            "system": system,
            "messages": messages,
            "max_tokens": max_tokens or self._s.llm_max_tokens,
        }

    async def complete(
        self, system: str, messages: list[dict[str, str]], max_tokens: int | None = None
    ) -> CompletionResult:
        async with httpx.AsyncClient(timeout=self._s.llm_timeout_seconds) as client:
            resp = await client.post(
                f"{_BASE}/messages",
                headers=self._headers,
                json=self._payload(system, messages, max_tokens),
            )
        if resp.status_code != 200:
            raise ApiError.internal(f"Anthropic completion failed ({resp.status_code})")
        data = resp.json()
        text = "".join(block.get("text", "") for block in data.get("content", []))
        usage = data.get("usage", {})
        return CompletionResult(
            text=text,
            prompt_tokens=int(usage.get("input_tokens", 0)),
            completion_tokens=int(usage.get("output_tokens", 0)),
        )

    async def stream(
        self, system: str, messages: list[dict[str, str]], max_tokens: int | None = None
    ) -> AsyncIterator[str]:
        payload = {**self._payload(system, messages, max_tokens), "stream": True}
        async with (
            httpx.AsyncClient(timeout=self._s.llm_timeout_seconds) as client,
            client.stream("POST", f"{_BASE}/messages", headers=self._headers, json=payload) as resp,
        ):
            if resp.status_code != 200:
                raise ApiError.internal(f"Anthropic stream failed ({resp.status_code})")
            async for line in resp.aiter_lines():
                if not line.startswith("data:"):
                    continue
                event = json.loads(line[len("data:") :].strip())
                if event.get("type") == "content_block_delta":
                    delta = event.get("delta", {})
                    if delta.get("type") == "text_delta" and delta.get("text"):
                        yield delta["text"]
                elif event.get("type") == "message_stop":
                    break

"""Slack incoming-webhook notifier."""

from __future__ import annotations

import httpx

from app.config import Settings
from app.errors import ConfigError, RateLimitError
from app.handoff.types import Notifier


class SlackNotifier(Notifier):
    def __init__(self, settings: Settings):
        self._s = settings

    def notify(self, text: str) -> None:
        if not self._s.slack_webhook_url:
            raise ConfigError("Slack (SLACK_WEBHOOK_URL)")
        with httpx.Client(timeout=self._s.llm_timeout_seconds) as client:
            resp = client.post(self._s.slack_webhook_url, json={"text": text})
        if resp.status_code == 429:
            try:
                retry_after = float(resp.headers.get("retry-after", "1"))
            except ValueError:
                retry_after = 1.0
            raise RateLimitError(retry_after)
        if resp.status_code >= 400:
            raise RuntimeError(f"Slack notify failed: {resp.status_code} {resp.text[:200]}")

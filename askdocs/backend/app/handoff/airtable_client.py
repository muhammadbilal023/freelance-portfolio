"""Airtable ticket client (the CRM-less option from the spec)."""

from __future__ import annotations

from typing import Any

import httpx

from app.config import Settings
from app.errors import ConfigError, RateLimitError
from app.handoff.types import TicketClient


class AirtableTicketClient(TicketClient):
    def __init__(self, settings: Settings):
        self._s = settings

    def create_ticket(self, fields: dict[str, Any]) -> str:
        if not self._s.airtable_api_key or not self._s.airtable_base_id:
            raise ConfigError("Airtable (AIRTABLE_API_KEY / AIRTABLE_BASE_ID)")
        table = self._s.airtable_tickets_table.replace(" ", "%20")
        url = f"https://api.airtable.com/v0/{self._s.airtable_base_id}/{table}"
        headers = {"Authorization": f"Bearer {self._s.airtable_api_key}"}
        with httpx.Client(timeout=self._s.llm_timeout_seconds) as client:
            resp = client.post(url, headers=headers, json={"fields": fields})
        if resp.status_code == 429:
            raise RateLimitError(_retry_after(resp))
        if resp.status_code >= 400:
            raise RuntimeError(f"Airtable create failed: {resp.status_code} {resp.text[:200]}")
        record_id = resp.json()["id"]
        return f"https://airtable.com/{self._s.airtable_base_id}/{table}/{record_id}"


def _retry_after(resp: httpx.Response) -> float:
    try:
        return float(resp.headers.get("retry-after", "1"))
    except ValueError:
        return 1.0

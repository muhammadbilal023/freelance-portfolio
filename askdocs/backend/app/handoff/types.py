"""Interfaces for handoff delivery (a ticket store and a notifier)."""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any


class TicketClient(ABC):
    @abstractmethod
    def create_ticket(self, fields: dict[str, Any]) -> str:
        """Create a support ticket; return a url or id for it."""


class Notifier(ABC):
    @abstractmethod
    def notify(self, text: str) -> None:
        """Send a human-readable alert to the support channel."""

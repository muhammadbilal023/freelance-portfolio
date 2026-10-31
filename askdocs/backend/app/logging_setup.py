"""Structured JSON logging built on the stdlib, with secret redaction.

Any secret configured in Settings (API keys, tokens, webhook URLs) is masked
everywhere it could appear: message strings and `extra` field values.
"""

from __future__ import annotations

import json
import logging
import sys
from datetime import UTC, datetime

_REDACTED = "[redacted]"


class RedactionFilter(logging.Filter):
    """Masks configured secret values in messages and extra fields."""

    def __init__(self) -> None:
        super().__init__()
        self._secrets: list[str] = []

    def set_secrets(self, secrets: list[str]) -> None:
        # Longest first so overlapping substrings are masked fully.
        self._secrets = sorted({s for s in secrets if s}, key=len, reverse=True)

    def filter(self, record: logging.LogRecord) -> bool:
        if not self._secrets:
            return True
        msg = str(record.getMessage())
        for secret in self._secrets:
            msg = msg.replace(secret, _REDACTED)
        record.msg = msg
        record.args = ()
        # `extras` is our own dict of structured fields (see JsonFormatter).
        extras = getattr(record, "extras", None)
        if isinstance(extras, dict):
            record.extras = {
                k: (
                    {sk: _REDACTED for sk, sv in v.items()}
                    if isinstance(v, dict)
                    else (_REDACTED if str(v) in self._secrets else v)
                )
                for k, v in extras.items()
            }
        return True


_REDACT_KEYS = {"authorization", "api_key", "x-api-key", "token", "secret", "webhook_url"}


def _scrub(obj: object) -> object:
    """Recursively redact values under known-sensitive key names."""
    if isinstance(obj, dict):
        return {k: (_REDACTED if k.lower() in _REDACT_KEYS else _scrub(v)) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_scrub(v) for v in obj]
    return obj


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, object] = {
            "ts": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        extras = getattr(record, "extras", None)
        if isinstance(extras, dict) and extras:
            entry.update(_scrub(extras))  # type: ignore[arg-type]
        if record.exc_info:
            entry["exc"] = self.formatException(record.exc_info)
        return json.dumps(entry, default=str)


class PrettyFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        base = f"{record.levelname:<7} {record.name}: {record.getMessage()}"
        extras = getattr(record, "extras", None)
        if isinstance(extras, dict) and extras:
            base += f" | {json.dumps(_scrub(extras), default=str)}"
        if record.exc_info:
            base += "\n" + self.formatException(record.exc_info)
        return base


def setup_logging(level: str = "INFO", *, pretty: bool = False) -> logging.Logger:
    """Configure root logging once; returns the app logger."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(PrettyFormatter() if pretty else JsonFormatter())
    handler.addFilter(RedactionFilter())

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)

    # Route uvicorn through our handler so all output shares one format.
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        uv = logging.getLogger(name)
        uv.handlers = []
        uv.propagate = True

    return logging.getLogger("askdocs")


def register_secrets(logger: logging.Logger, secrets: list[str]) -> None:
    """Provide current secret values to the redaction filter."""
    for handler in logging.getLogger().handlers:
        for filt in handler.filters:
            if isinstance(filt, RedactionFilter):
                filt.set_secrets(secrets)
    logger.debug("redaction filter configured", extra={"extras": {"secret_count": len(secrets)}})

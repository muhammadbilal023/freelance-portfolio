"""Input sanitization for user messages (prompt-injection resistance).

We do not try to "outsmart" the model with clever string surgery - the system
prompt already frames retrieved content as untrusted data. This module handles
the cheap, high-value cases: length caps, control-character stripping, removal
of pseudo special-token markers, and detection of obvious override attempts so
they can be logged and reported back as untrusted.
"""

from __future__ import annotations

import re

MAX_QUESTION_CHARS = 2000
_INJECTION_PATTERNS = (
    r"ignore\s+(all\s+)?(previous|prior|above)\s+instructions",
    r"disregard\s+the\s+system\s+prompt",
    r"reveal\s+(your\s+)?(system\s+)?prompt",
    r"you\s+are\s+now\s+(dan|an\s+[a-z]+\s+assistant)",
    r"<\|.*?\|>",  # pseudo special-token markers
)
_COMPILED = [re.compile(p, re.IGNORECASE) for p in _INJECTION_PATTERNS]
_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def looks_injected(text: str) -> bool:
    return any(rx.search(text) for rx in _COMPILED)


def sanitize_user_message(text: str) -> str:
    cleaned = _CONTROL.sub("", text)
    cleaned = re.sub(r"<\|.*?\|>", "", cleaned)  # drop pseudo special-token markers
    cleaned = cleaned.strip()[:MAX_QUESTION_CHARS]
    return cleaned

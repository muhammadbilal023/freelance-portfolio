"""Chunking: overlapping windows with sentence-boundary snapping.

We target ~800 characters (a coarse proxy for tokens that keeps the dependency
footprint small) with a 150-char overlap so context isn't severed at a window
edge. Chunk char offsets are relative to the page text, and page attribution is
preserved because we chunk each page independently.
"""

from __future__ import annotations

from dataclasses import dataclass

TARGET_CHARS = 800
OVERLAP_CHARS = 150
_TERMINATORS = (".", "!", "?", "\n")


@dataclass
class ChunkPiece:
    content: str
    page: int
    char_offset: int


def _snap_end(text: str, start: int, hard_end: int) -> int:
    """Pull `hard_end` back to the last sentence terminator in the latter half.

    Falls back to the last space, then the raw hard_end (a single long word/sentence).
    """
    floor = start + (hard_end - start) // 2
    for term in _TERMINATORS:
        idx = text.rfind(term, floor, hard_end)
        if idx != -1:
            return idx + 1  # include the terminator
    space = text.rfind(" ", floor, hard_end)
    return space if space != -1 else hard_end


def chunk_text(
    pages: list[tuple[int, str]],
    *,
    target_chars: int = TARGET_CHARS,
    overlap_chars: int = OVERLAP_CHARS,
) -> list[ChunkPiece]:
    if overlap_chars >= target_chars:
        raise ValueError("overlap must be smaller than target window")

    pieces: list[ChunkPiece] = []
    for page_no, raw in pages:
        text = raw.strip()
        if not text:
            continue
        start = 0
        n = len(text)
        while start < n:
            hard_end = min(start + target_chars, n)
            end = n if hard_end == n else _snap_end(text, start, hard_end)
            if end <= start:  # snapping produced no progress; force the hard window
                end = hard_end
            piece = text[start:end].strip()
            if piece:
                pieces.append(ChunkPiece(piece, page_no, start))
            if end >= n:
                break
            next_start = end - overlap_chars
            if next_start <= start:  # guarantee forward progress on short windows
                next_start = end
            start = next_start
    return pieces

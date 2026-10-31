"""Chunking: windows, overlap, page attribution, and empty handling."""

from __future__ import annotations

import pytest
from app.ingestion.chunker import TARGET_CHARS, chunk_text


def test_short_page_is_one_chunk() -> None:
    pieces = chunk_text([(1, "Hello world.")])
    assert len(pieces) == 1
    assert pieces[0].content == "Hello world."
    assert pieces[0].page == 1
    assert pieces[0].char_offset == 0


def test_empty_and_whitespace_pages_produce_nothing() -> None:
    assert chunk_text([]) == []
    assert chunk_text([(1, "   \n  ")]) == []


def test_overlap_makes_consecutive_chunks_share_text() -> None:
    # Two long sentences so the hard window (>TARGET_CHARS) is exercised.
    sentence = "The quick brown fox jumps over the lazy dog. " * 30  # ~1500 chars
    pieces = chunk_text([(1, sentence)])
    assert len(pieces) >= 2
    # With a positive overlap, the second chunk starts before the first ends.
    first_end = pieces[0].char_offset + len(pieces[0].content)
    assert pieces[1].char_offset < first_end


def test_page_attribution_is_per_page() -> None:
    long = "word " * 400  # > TARGET_CHARS, spans two windows on its own
    pieces = chunk_text([(1, long), (2, "second page text.")])
    pages = {p.page for p in pieces}
    assert pages == {1, 2}
    last = pieces[-1]
    assert last.page == 2
    assert last.content.startswith("second page")


def test_offsets_are_relative_to_page_text() -> None:
    body = "abcdefghij klmnopqrst " * 100
    pieces = chunk_text([(1, body)])
    # Reconstruct: every piece must be a substring located at its reported offset.
    for p in pieces:
        assert body[p.char_offset : p.char_offset + len(p.content)].strip() == p.content


def test_overlap_larger_than_target_is_rejected() -> None:
    with pytest.raises(ValueError):
        chunk_text([(1, "text")], target_chars=10, overlap_chars=10)


def test_target_window_is_respected() -> None:
    body = "x" * (TARGET_CHARS * 3)
    pieces = chunk_text([(1, body)])
    assert all(len(p.content) <= TARGET_CHARS for p in pieces)

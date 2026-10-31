"""Retrieval ranking, threshold rejection, and per-document isolation."""

from __future__ import annotations

import pytest
from app.ingestion.pipeline import delete_document, ingest_document
from app.main import Container
from app.rag.retriever import retrieve


def _ingest(c: Container, file_name: str, text: str) -> int:
    summary = ingest_document(
        documents=c.documents,
        chunks=c.chunks,
        vectors=c.vectors,
        embedder=c.embedder,
        file_name=file_name,
        data=text.encode("utf-8"),
    )
    return int(summary["id"])


def _retrieve(c: Container, query: str, *, top_k: int = 4, min_score: float = 0.0):
    return retrieve(
        vectors=c.vectors,
        documents=c.documents,
        embedder=c.embedder,
        query=query,
        top_k=top_k,
        min_score=min_score,
        chunks_repo=c.chunks,
    )


def test_identical_query_retrieves_its_chunk(container: Container) -> None:
    _ingest(container, "returns.txt", "Refunds are processed within five business days.")
    hits = _retrieve(container, "Refunds are processed within five business days.", min_score=0.9)
    assert hits
    assert hits[0].file_name == "returns.txt"
    assert hits[0].score == pytest.approx(1.0)


def test_threshold_rejects_unrelated_query(container: Container) -> None:
    _ingest(container, "returns.txt", "Refunds are processed within five business days.")
    # Disjoint vocabulary -> cosine ~0 -> normalized score ~0.5, below 0.9.
    assert _retrieve(container, "banana tractor calendar", min_score=0.9) == []
    # The same hit clears a low threshold, proving it's the floor doing the work.
    assert _retrieve(container, "banana tractor calendar", min_score=0.2)


def test_retrieval_is_isolated_to_the_matching_document(container: Container) -> None:
    _ingest(container, "shipping.txt", "We ship orders on weekdays via courier.")
    _ingest(container, "pricing.txt", "Membership costs ten dollars each month.")
    hits = _retrieve(container, "when do you ship orders", top_k=4, min_score=0.3)
    assert hits
    assert hits[0].file_name == "shipping.txt"


def test_top_k_limits_result_count(container: Container) -> None:
    _ingest(container, "big.txt", "alpha beta " * 500)  # several chunks, all similar
    all_hits = _retrieve(container, "alpha beta", top_k=10, min_score=0.0)
    capped = _retrieve(container, "alpha beta", top_k=2, min_score=0.0)
    assert len(all_hits) > len(capped)
    assert len(capped) <= 2


def test_deleted_document_no_longer_retrieved(container: Container) -> None:
    doc_id = _ingest(container, "temp.txt", "Temporary policy about widgets.")
    assert _retrieve(container, "policy about widgets", min_score=0.5)
    delete_document(documents=container.documents, vectors=container.vectors, doc_id=doc_id)
    assert _retrieve(container, "policy about widgets", min_score=0.5) == []

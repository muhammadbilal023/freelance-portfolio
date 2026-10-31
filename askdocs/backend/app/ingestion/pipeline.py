"""End-to-end ingestion: bytes -> stored, embedded chunks.

Kept synchronous on purpose: `embed` is a blocking HTTP call, so the route runs
this in a threadpool. Splitting extract/chunk/embed/store lets each be unit-
tested without a server.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from app.db.repositories import VectorStore
from app.ingestion.chunker import chunk_text
from app.ingestion.extractors import detect_type, extract_pages
from app.llm.base import Embedder

if TYPE_CHECKING:
    from app.db.repositories import ChunksRepository, DocumentsRepository


def ingest_document(
    *,
    documents: DocumentsRepository,
    chunks: ChunksRepository,
    vectors: VectorStore,
    embedder: Embedder,
    file_name: str,
    data: bytes,
) -> dict[str, Any]:
    doc_type = detect_type(file_name)  # raises on unsupported extension
    pages = extract_pages(file_name, data)
    pieces = chunk_text(pages)

    doc_id = documents.create(file_name, doc_type, num_pages=len(pages))
    if not pieces:
        documents.set_chunk_count(doc_id, 0)
        return {
            "id": doc_id,
            "file_name": file_name,
            "doc_type": doc_type,
            "num_pages": len(pages),
            "num_chunks": 0,
        }

    embeddings = embedder.embed([p.content for p in pieces])
    chunk_ids = chunks.insert_many(doc_id, [(p.content, p.page, p.char_offset) for p in pieces])
    for chunk_id, embedding in zip(chunk_ids, embeddings, strict=True):
        vectors.upsert(chunk_id, doc_id, embedding)
    documents.set_chunk_count(doc_id, len(pieces))

    return {
        "id": doc_id,
        "file_name": file_name,
        "doc_type": doc_type,
        "num_pages": len(pages),
        "num_chunks": len(pieces),
    }


def delete_document(*, documents: DocumentsRepository, vectors: VectorStore, doc_id: int) -> bool:
    if documents.get(doc_id) is None:
        return False
    vectors.delete_for_document(doc_id)  # removes vec-index rows where the index exists
    documents.delete(doc_id)  # cascades to chunks (and their stored embeddings)
    return True

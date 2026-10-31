"""Vector retrieval: embed query, rank chunks, drop below-threshold hits."""

from __future__ import annotations

from dataclasses import dataclass

from app.db.repositories import DocumentsRepository, VectorStore
from app.llm.base import Embedder


@dataclass
class RetrievedChunk:
    chunk_id: int
    document_id: int
    file_name: str
    page: int
    content: str
    score: float


def retrieve(
    *,
    vectors: VectorStore,
    documents: DocumentsRepository,
    embedder: Embedder,
    query: str,
    top_k: int,
    min_score: float,
    chunks_repo,  # ChunksRepository - typed loosely to avoid an import cycle
) -> list[RetrievedChunk]:
    if not query.strip():
        return []
    query_vec = embedder.embed([query])[0]
    hits = vectors.query(query_vec, k=top_k)
    results: list[RetrievedChunk] = []
    seen: set[int] = set()
    for chunk_id, _doc_id, score in hits:
        if score < min_score:
            continue
        chunk = chunks_repo.get(chunk_id)
        if chunk is None or chunk_id in seen:
            continue
        seen.add(chunk_id)
        doc = documents.get(chunk.document_id)
        if doc is None:
            continue
        results.append(
            RetrievedChunk(
                chunk_id=chunk_id,
                document_id=doc.id,
                file_name=doc.file_name,
                page=chunk.page,
                content=chunk.content,
                score=score,
            )
        )
    return results

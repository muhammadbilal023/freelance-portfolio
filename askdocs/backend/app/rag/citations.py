"""Citations: turn retrieved chunks into source references + prompt context.

Each context block is labeled with a stable [S#] id that the model is asked to
cite; we keep the id -> source mapping so the API can return structured
citations (file name + page) alongside the answer.
"""

from __future__ import annotations

from typing import Any

from app.rag.retriever import RetrievedChunk

SNIPPET_CHARS = 200


def to_citation(rc: RetrievedChunk) -> dict[str, Any]:
    snippet = rc.content[:SNIPPET_CHARS]
    if len(rc.content) > SNIPPET_CHARS:
        snippet += "…"
    return {
        "file_name": rc.file_name,
        "page": rc.page,
        "chunk_id": rc.chunk_id,
        "snippet": snippet,
        "score": round(rc.score, 4),
    }


def build_context(retrieved: list[RetrievedChunk]) -> tuple[str, list[dict[str, Any]]]:
    """Return (context_block_for_prompt, citations_list).

    Citations are ordered by first appearance; the same source used by several
    chunks keeps one id.
    """
    citations: list[dict[str, Any]] = []
    id_by_chunk: dict[int, int] = {}
    blocks: list[str] = []
    for rc in retrieved:
        sid = id_by_chunk.get(rc.chunk_id)
        if sid is None:
            sid = len(citations) + 1
            id_by_chunk[rc.chunk_id] = sid
            citations.append({"id": sid, **to_citation(rc)})
        blocks.append(f"[S{sid}] (source: {rc.file_name}, page {rc.page})\n{rc.content}")
    return "\n\n".join(blocks), citations

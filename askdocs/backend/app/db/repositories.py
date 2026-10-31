"""Repository classes: the only place that touches SQL.

Kept deliberately thin and table-oriented so a future PostgreSQL/pgvector
migration is a contained change (same method signatures, different driver).
"""

from __future__ import annotations

import json
import math
import sqlite3
import struct
import time
from dataclasses import dataclass
from typing import Any

# --------------------------------------------------------------------------- #
# row types
# --------------------------------------------------------------------------- #


@dataclass
class Document:
    id: int
    file_name: str
    doc_type: str
    num_pages: int
    num_chunks: int
    created_at: str


@dataclass
class Chunk:
    id: int
    document_id: int
    chunk_index: int
    content: str
    page: int
    char_offset: int


@dataclass
class Message:
    id: int
    session_id: str
    role: str
    content: str
    citations: list[dict[str, Any]] | None
    created_at: str
    prompt_tokens: int
    completion_tokens: int
    handoff_triggered: bool


@dataclass
class Job:
    id: int
    type: str
    payload: dict[str, Any]
    status: str
    attempts: int
    max_attempts: int
    next_retry_at: int
    last_error: str | None


def _job_from_row(row: sqlite3.Row) -> Job:
    return Job(
        id=row["id"],
        type=row["type"],
        payload=json.loads(row["payload"]),
        status=row["status"],
        attempts=row["attempts"],
        max_attempts=row["max_attempts"],
        next_retry_at=row["next_retry_at"],
        last_error=row["last_error"],
    )


def _message_from_row(row: sqlite3.Row) -> Message:
    return Message(
        id=row["id"],
        session_id=row["session_id"],
        role=row["role"],
        content=row["content"],
        citations=json.loads(row["citations"]) if row["citations"] else None,
        created_at=row["created_at"],
        prompt_tokens=row["prompt_tokens"],
        completion_tokens=row["completion_tokens"],
        handoff_triggered=bool(row["handoff_triggered"]),
    )


def serialize_vector(vec: list[float]) -> bytes:
    """sqlite-vec expects float32 little-endian packed bytes."""
    return struct.pack(f"<{len(vec)}f", *vec)


def deserialize_vector(blob: bytes) -> list[float]:
    n = len(blob) // 4
    return list(struct.unpack(f"<{n}f", blob))


def _cosine_similarity(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b, strict=False))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


# --------------------------------------------------------------------------- #
# documents / chunks / vectors
# --------------------------------------------------------------------------- #


class DocumentsRepository:
    def __init__(self, conn: sqlite3.Connection):
        self._conn = conn

    def create(self, file_name: str, doc_type: str, num_pages: int) -> int:
        cur = self._conn.execute(
            "INSERT INTO documents (file_name, doc_type, num_pages) VALUES (?, ?, ?)",
            (file_name, doc_type, num_pages),
        )
        self._conn.commit()
        return int(cur.lastrowid)

    def set_chunk_count(self, document_id: int, num_chunks: int) -> None:
        self._conn.execute(
            "UPDATE documents SET num_chunks = ? WHERE id = ?", (num_chunks, document_id)
        )
        self._conn.commit()

    def get(self, document_id: int) -> Document | None:
        row = self._conn.execute("SELECT * FROM documents WHERE id = ?", (document_id,)).fetchone()
        return self._to_doc(row)

    def list_all(self) -> list[Document]:
        rows = self._conn.execute("SELECT * FROM documents ORDER BY id DESC").fetchall()
        return [self._to_doc(r) for r in rows]

    def delete(self, document_id: int) -> bool:
        self._conn.execute("DELETE FROM chunks WHERE document_id = ?", (document_id,))
        cur = self._conn.execute("DELETE FROM documents WHERE id = ?", (document_id,))
        self._conn.commit()
        return cur.rowcount == 1

    def count(self) -> int:
        return int(self._conn.execute("SELECT COUNT(*) FROM documents").fetchone()[0])

    @staticmethod
    def _to_doc(row: sqlite3.Row | None) -> Document | None:
        if row is None:
            return None
        return Document(
            id=row["id"],
            file_name=row["file_name"],
            doc_type=row["doc_type"],
            num_pages=row["num_pages"],
            num_chunks=row["num_chunks"],
            created_at=row["created_at"],
        )


class ChunksRepository:
    def __init__(self, conn: sqlite3.Connection):
        self._conn = conn

    def insert_many(self, document_id: int, items: list[tuple[str, int, int]]) -> list[int]:
        """items = [(content, page, char_offset), ...] in chunk order."""
        ids: list[int] = []
        for index, (content, page, offset) in enumerate(items):
            cur = self._conn.execute(
                "INSERT INTO chunks (document_id, chunk_index, content, page, char_offset)"
                " VALUES (?, ?, ?, ?, ?)",
                (document_id, index, content, page, offset),
            )
            ids.append(int(cur.lastrowid))
        self._conn.commit()
        return ids

    def for_document(self, document_id: int) -> list[Chunk]:
        rows = self._conn.execute(
            "SELECT * FROM chunks WHERE document_id = ? ORDER BY chunk_index", (document_id,)
        ).fetchall()
        return [
            Chunk(
                id=r["id"],
                document_id=r["document_id"],
                chunk_index=r["chunk_index"],
                content=r["content"],
                page=r["page"],
                char_offset=r["char_offset"],
            )
            for r in rows
        ]

    def get(self, chunk_id: int) -> Chunk | None:
        r = self._conn.execute("SELECT * FROM chunks WHERE id = ?", (chunk_id,)).fetchone()
        if r is None:
            return None
        return Chunk(
            id=r["id"],
            document_id=r["document_id"],
            chunk_index=r["chunk_index"],
            content=r["content"],
            page=r["page"],
            char_offset=r["char_offset"],
        )

    def delete_for_document(self, document_id: int) -> None:
        self._conn.execute("DELETE FROM chunks WHERE document_id = ?", (document_id,))
        self._conn.commit()


class VectorStore:
    """ANN search with a guaranteed-correct fallback.

    Embeddings always live in chunks.embedding (float32 BLOB - the source of
    truth). Where sqlite-vec can load, the same vectors are mirrored into the
    vec_chunks virtual table for indexed kNN. Without it (e.g. stock Windows
    CPython), query() does an in-process cosine scan - identical results,
    linear time, which is fine at this dataset scale.

    Scores are normalized to (0, 1]: 1/(1+d²) from sqlite-vec's L2 distance
    (equivalent ranking to cosine for unit-normalized embeddings), and
    (1+cos)/2 from the scan path. Thresholds are set against these ranges.
    """

    def __init__(self, conn: sqlite3.Connection, *, vec_available: bool):
        self._conn = conn
        self._vec = vec_available

    def upsert(self, chunk_id: int, document_id: int, embedding: list[float]) -> None:
        packed = serialize_vector(embedding)
        self._conn.execute("UPDATE chunks SET embedding = ? WHERE id = ?", (packed, chunk_id))
        if self._vec:
            self._conn.execute("DELETE FROM vec_chunks WHERE rowid = ?", (chunk_id,))
            self._conn.execute(
                "INSERT INTO vec_chunks (rowid, embedding, document_id) VALUES (?, ?, ?)",
                (chunk_id, packed, document_id),
            )
        self._conn.commit()

    def delete_for_document(self, document_id: int) -> None:
        if self._vec:
            self._conn.execute("DELETE FROM vec_chunks WHERE document_id = ?", (document_id,))
        self._conn.commit()

    def query(self, embedding: list[float], k: int) -> list[tuple[int, int, float]]:
        """Return [(chunk_id, document_id, score)] best-match-first."""
        if self._vec:
            rows = self._conn.execute(
                "SELECT rowid, document_id, distance FROM vec_chunks"
                " WHERE embedding MATCH ? AND k = ? ORDER BY distance",
                (serialize_vector(embedding), k),
            ).fetchall()
            return [
                (int(r["rowid"]), int(r["document_id"]), 1.0 / (1.0 + float(r["distance"]) ** 2))
                for r in rows
            ]
        return self._scan_query(embedding, k)

    def _scan_query(self, embedding: list[float], k: int) -> list[tuple[int, int, float]]:
        rows = self._conn.execute(
            "SELECT id, document_id, embedding FROM chunks WHERE embedding IS NOT NULL"
        ).fetchall()
        scored: list[tuple[int, int, float]] = []
        for r in rows:
            sim = _cosine_similarity(embedding, deserialize_vector(r["embedding"]))
            scored.append((int(r["id"]), int(r["document_id"]), (1.0 + sim) / 2.0))
        scored.sort(key=lambda t: t[2], reverse=True)
        return scored[:k]

    def count(self) -> int:
        return int(
            self._conn.execute(
                "SELECT COUNT(*) FROM chunks WHERE embedding IS NOT NULL"
            ).fetchone()[0]
        )


# --------------------------------------------------------------------------- #
# chat: sessions / messages / feedback
# --------------------------------------------------------------------------- #


class SessionsRepository:
    def __init__(self, conn: sqlite3.Connection):
        self._conn = conn

    def create(self, session_id: str, user_id: str) -> None:
        self._conn.execute(
            "INSERT INTO sessions (id, user_id) VALUES (?, ?)", (session_id, user_id)
        )
        self._conn.commit()

    def get(self, session_id: str) -> tuple[str, str] | None:
        """Returns (session_id, user_id) or None."""
        row = self._conn.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
        return (row["id"], row["user_id"]) if row else None


class MessagesRepository:
    def __init__(self, conn: sqlite3.Connection):
        self._conn = conn

    def add(
        self,
        session_id: str,
        role: str,
        content: str,
        citations: list[dict[str, Any]] | None = None,
        prompt_tokens: int = 0,
        completion_tokens: int = 0,
    ) -> Message:
        cur = self._conn.execute(
            "INSERT INTO messages (session_id, role, content, citations, prompt_tokens,"
            " completion_tokens) VALUES (?, ?, ?, ?, ?, ?)",
            (
                session_id,
                role,
                content,
                json.dumps(citations) if citations else None,
                prompt_tokens,
                completion_tokens,
            ),
        )
        self._conn.commit()
        row = self._conn.execute("SELECT * FROM messages WHERE id = ?", (cur.lastrowid,)).fetchone()
        return _message_from_row(row)

    def get(self, message_id: int) -> Message | None:
        row = self._conn.execute("SELECT * FROM messages WHERE id = ?", (message_id,)).fetchone()
        return _message_from_row(row) if row else None

    def history(self, session_id: str, limit: int = 20) -> list[Message]:
        """Most recent messages, oldest-first."""
        rows = self._conn.execute(
            "SELECT * FROM (SELECT * FROM messages WHERE session_id = ? ORDER BY id DESC LIMIT ?)"
            " ORDER BY id ASC",
            (session_id, limit),
        ).fetchall()
        return [_message_from_row(r) for r in rows]

    def mark_handoff(self, message_id: int) -> None:
        self._conn.execute("UPDATE messages SET handoff_triggered = 1 WHERE id = ?", (message_id,))
        self._conn.commit()

    def token_totals(self) -> tuple[int, int]:
        row = self._conn.execute(
            "SELECT COALESCE(SUM(prompt_tokens),0) AS p, COALESCE(SUM(completion_tokens),0) AS c"
            " FROM messages"
        ).fetchone()
        return int(row["p"]), int(row["c"])


class FeedbackRepository:
    def __init__(self, conn: sqlite3.Connection):
        self._conn = conn

    def add(self, message_id: int, session_id: str, rating: str) -> None:
        self._conn.execute(
            "INSERT INTO feedback (message_id, session_id, rating) VALUES (?, ?, ?)",
            (message_id, session_id, rating),
        )
        self._conn.commit()

    def negative_count_for_session(self, session_id: str) -> int:
        row = self._conn.execute(
            "SELECT COUNT(*) FROM feedback WHERE session_id = ? AND rating = 'not_helpful'",
            (session_id,),
        ).fetchone()
        return int(row[0])

    def list_recent(self, limit: int = 50) -> list[dict[str, Any]]:
        rows = self._conn.execute(
            "SELECT f.*, m.content FROM feedback f JOIN messages m ON m.id = f.message_id"
            " ORDER BY f.id DESC LIMIT ?",
            (limit,),
        ).fetchall()
        return [dict(r) for r in rows]

    def counts(self) -> dict[str, int]:
        rows = self._conn.execute(
            "SELECT rating, COUNT(*) AS n FROM feedback GROUP BY rating"
        ).fetchall()
        return {r["rating"]: int(r["n"]) for r in rows}


# --------------------------------------------------------------------------- #
# job queue (same semantics as SyncFlow's JobsRepository)
# --------------------------------------------------------------------------- #


class JobsRepository:
    def __init__(self, conn: sqlite3.Connection):
        self._conn = conn

    def enqueue(self, type_: str, payload: dict[str, Any], max_attempts: int) -> int:
        cur = self._conn.execute(
            "INSERT INTO jobs (type, payload, status, max_attempts, next_retry_at)"
            " VALUES (?, ?, 'queued', ?, 0)",
            (type_, json.dumps(payload), max_attempts),
        )
        self._conn.commit()
        return int(cur.lastrowid)

    def claim_next_due(self) -> Job | None:
        """Atomically claim the oldest due queued job (conditional UPDATE)."""
        now_ms = _now_ms()
        row = self._conn.execute(
            "SELECT id FROM jobs WHERE status = 'queued' AND next_retry_at <= ?"
            " ORDER BY next_retry_at ASC, id ASC LIMIT 1",
            (now_ms,),
        ).fetchone()
        if row is None:
            return None
        cur = self._conn.execute(
            "UPDATE jobs SET status = 'running', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')"
            " WHERE id = ? AND status = 'queued'",
            (row["id"],),
        )
        self._conn.commit()
        if cur.rowcount != 1:
            return None  # lost a race to another claimant
        full = self._conn.execute("SELECT * FROM jobs WHERE id = ?", (row["id"],)).fetchone()
        return _job_from_row(full)

    def mark_succeeded(self, job_id: int) -> None:
        self._conn.execute(
            "UPDATE jobs SET status = 'succeeded', last_error = NULL,"
            " updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?",
            (job_id,),
        )
        self._conn.commit()

    def requeue_for_retry(self, job_id: int, error: str, next_retry_at_ms: int) -> None:
        self._conn.execute(
            "UPDATE jobs SET status = 'queued', attempts = attempts + 1, last_error = ?,"
            " next_retry_at = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?",
            (error, next_retry_at_ms, job_id),
        )
        self._conn.commit()

    def mark_dead(self, job_id: int, error: str) -> None:
        self._conn.execute(
            "UPDATE jobs SET status = 'dead', attempts = attempts + 1, last_error = ?,"
            " updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?",
            (error, job_id),
        )
        self._conn.commit()

    def get(self, job_id: int) -> Job | None:
        row = self._conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
        return _job_from_row(row) if row else None

    def reset_to_queued(self, job_id: int) -> bool:
        cur = self._conn.execute(
            "UPDATE jobs SET status = 'queued', attempts = 0, next_retry_at = 0,"
            " last_error = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')"
            " WHERE id = ? AND status IN ('dead', 'succeeded')",
            (job_id,),
        )
        self._conn.commit()
        return cur.rowcount == 1

    def list_recent(self, limit: int = 50) -> list[Job]:
        rows = self._conn.execute(
            "SELECT * FROM jobs ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
        return [_job_from_row(r) for r in rows]

    def count_by_status(self) -> dict[str, int]:
        rows = self._conn.execute(
            "SELECT status, COUNT(*) AS n FROM jobs GROUP BY status"
        ).fetchall()
        return {r["status"]: int(r["n"]) for r in rows}


class DeadLettersRepository:
    def __init__(self, conn: sqlite3.Connection):
        self._conn = conn

    def insert(self, job: Job, error: str) -> int:
        cur = self._conn.execute(
            "INSERT INTO dead_letters (job_id, type, payload, error, attempts)"
            " VALUES (?, ?, ?, ?, ?)",
            (job.id, job.type, json.dumps(job.payload), error, job.attempts),
        )
        self._conn.commit()
        return int(cur.lastrowid)

    def get(self, dead_letter_id: int) -> dict[str, Any] | None:
        row = self._conn.execute(
            "SELECT * FROM dead_letters WHERE id = ?", (dead_letter_id,)
        ).fetchone()
        if row is None:
            return None
        d = dict(row)
        d["payload"] = json.loads(d["payload"])
        return d

    def mark_retried(self, dead_letter_id: int) -> None:
        self._conn.execute(
            "UPDATE dead_letters SET retried_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?",
            (dead_letter_id,),
        )
        self._conn.commit()

    def list_recent(self, limit: int = 50) -> list[dict[str, Any]]:
        rows = self._conn.execute(
            "SELECT * FROM dead_letters ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
        out = []
        for r in rows:
            d = dict(r)
            d["payload"] = json.loads(d["payload"])
            out.append(d)
        return out

    def count(self) -> int:
        return int(self._conn.execute("SELECT COUNT(*) FROM dead_letters").fetchone()[0])


class WebhookEventsRepository:
    """Idempotency ledger; also guards handoff triggers against double-firing."""

    def __init__(self, conn: sqlite3.Connection):
        self._conn = conn

    def record(self, provider: str, external_event_id: str, event_type: str, payload: Any) -> bool:
        """Returns True if new (accepted), False if already seen (duplicate)."""
        body = json.dumps(payload) if payload is not None else None
        cur = self._conn.execute(
            "INSERT INTO webhook_events (provider, external_event_id, event_type, payload, status)"
            " VALUES (?, ?, ?, ?, 'accepted')"
            " ON CONFLICT(provider, external_event_id) DO NOTHING",
            (provider, external_event_id, event_type, body),
        )
        if cur.rowcount == 1:
            self._conn.commit()
            return True
        self._conn.execute(
            "UPDATE webhook_events SET status = 'duplicate' WHERE provider = ?"
            " AND external_event_id = ?",
            (provider, external_event_id),
        )
        self._conn.commit()
        return False

    def list_recent(self, limit: int = 50) -> list[dict[str, Any]]:
        rows = self._conn.execute(
            "SELECT * FROM webhook_events ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
        return [dict(r) for r in rows]


def _now_ms() -> int:
    return int(time.time() * 1000)

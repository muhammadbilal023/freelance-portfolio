"""SQLite connection + schema management (WAL mode, sqlite-vec virtual table)."""

from __future__ import annotations

import sqlite3
from pathlib import Path

import sqlite_vec

SCHEMA = """
CREATE TABLE IF NOT EXISTS documents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_name TEXT NOT NULL,
    doc_type TEXT NOT NULL,
    num_pages INTEGER NOT NULL DEFAULT 1,
    num_chunks INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    chunk_index INTEGER NOT NULL,
    content TEXT NOT NULL,
    page INTEGER NOT NULL DEFAULT 1,
    char_offset INTEGER NOT NULL DEFAULT 0,
    embedding BLOB
);

CREATE INDEX IF NOT EXISTS idx_chunks_document ON chunks(document_id);

CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('user','assistant')),
    content TEXT NOT NULL,
    citations TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    prompt_tokens INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    handoff_triggered INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, id);

CREATE TABLE IF NOT EXISTS feedback (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    session_id TEXT NOT NULL,
    rating TEXT NOT NULL CHECK (rating IN ('helpful','not_helpful')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    type TEXT NOT NULL,
    payload TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('queued','running','succeeded','dead')),
    attempts INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL,
    next_retry_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_jobs_due ON jobs(status, next_retry_at);

CREATE TABLE IF NOT EXISTS dead_letters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id INTEGER NOT NULL,
    type TEXT NOT NULL,
    payload TEXT NOT NULL,
    error TEXT NOT NULL,
    attempts INTEGER NOT NULL,
    died_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    retried_at TEXT
);

CREATE TABLE IF NOT EXISTS webhook_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider TEXT NOT NULL,
    external_event_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload TEXT,
    status TEXT NOT NULL CHECK (status IN ('accepted','duplicate')),
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    UNIQUE(provider, external_event_id)
);
"""

VEC_TABLE = (
    "CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0("
    "rowid INTEGER PRIMARY KEY, embedding float[{dim}], document_id INTEGER)"
)

# sqlite3.Connection objects don't allow custom attributes, so remember per-connection
# capability by object id (connections live for the app's lifetime; entries are tiny).
_vec_flag_by_conn_id: dict[int, bool] = {}


def open_database(path: str, embedding_dim: int) -> tuple[sqlite3.Connection, bool]:
    """Open (and initialize) the database at `path` (':memory:' for throwaway).

    Returns (connection, vec_index_available). The sqlite-vec virtual table is
    an optional index; embeddings always live in chunks.embedding so the store
    degrades to an in-process cosine scan on builds that cannot load
    extensions (stock Windows CPython).
    """
    if path != ":memory:":
        Path(path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    vec_available = _load_vec_extension(conn)
    conn.executescript(SCHEMA)
    if vec_available:
        conn.execute(VEC_TABLE.format(dim=embedding_dim))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.commit()
    # Only record positive results; stale ids after a connection dies can never
    # turn a False into a True because False is the lookup default.
    if vec_available:
        _vec_flag_by_conn_id[id(conn)] = True
    return conn, vec_available


def is_vec_available(conn: sqlite3.Connection) -> bool:
    """Whether `conn` was opened with the sqlite-vec index (False for foreign conns)."""
    return _vec_flag_by_conn_id.get(id(conn), False)


def _load_vec_extension(conn: sqlite3.Connection) -> bool:
    """Try to register sqlite-vec; False when this build cannot load extensions."""
    enable = getattr(sqlite3, "enable_load_extension", None)
    if enable is None:
        return False
    try:
        enable(conn)
        conn.load_extension(sqlite_vec.loadable_path())
        return True
    except sqlite3.Error:
        return False

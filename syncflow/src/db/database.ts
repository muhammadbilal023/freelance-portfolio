import fs from 'node:fs';
import path from 'node:path';
import Database from 'better-sqlite3';

/**
 * Schema is idempotent (IF NOT EXISTS) so the same code path runs on first
 * start and every restart. For a real multi-node deployment this would be
 * replaced by numbered migrations — see README.
 */
const SCHEMA = `
CREATE TABLE IF NOT EXISTS webhook_events (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  provider         TEXT NOT NULL,
  external_event_id TEXT NOT NULL,
  event_type       TEXT NOT NULL,
  payload          TEXT NOT NULL,
  status           TEXT NOT NULL DEFAULT 'accepted', -- accepted | duplicate
  received_at      TEXT NOT NULL,
  UNIQUE (provider, external_event_id)
);

CREATE TABLE IF NOT EXISTS jobs (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  type          TEXT NOT NULL,
  payload       TEXT NOT NULL,          -- JSON
  status        TEXT NOT NULL DEFAULT 'queued', -- queued | running | succeeded | dead
  attempts      INTEGER NOT NULL DEFAULT 0,
  max_attempts  INTEGER NOT NULL,
  next_retry_at INTEGER NOT NULL,       -- epoch ms; due immediately when <= now
  last_error    TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_jobs_due ON jobs (status, next_retry_at);

-- Dead-letter table: jobs whose retries are exhausted are copied here so
-- failures survive and can be inspected / retried from the admin dashboard.
CREATE TABLE IF NOT EXISTS dead_letters (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id     INTEGER NOT NULL,
  type       TEXT NOT NULL,
  payload    TEXT NOT NULL,
  error      TEXT NOT NULL,
  attempts   INTEGER NOT NULL,
  died_at    TEXT NOT NULL,
  retried_at TEXT                        -- set when re-queued from the dashboard
);

-- Duplicate protection for scheduled pulls (Flow 3): one row per source
-- record that has already been synced.
CREATE TABLE IF NOT EXISTS sync_ledger (
  source    TEXT NOT NULL,
  record_id TEXT NOT NULL,
  synced_at TEXT NOT NULL,
  PRIMARY KEY (source, record_id)
);
`;

export type SqliteDatabase = Database.Database;

export function openDatabase(dbPath: string): SqliteDatabase {
  if (dbPath !== ':memory:') {
    fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  }
  const db = new Database(dbPath);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.exec(SCHEMA);
  return db;
}

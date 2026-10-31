import type { SqliteDatabase } from './database.js';

// ---- Row types ---------------------------------------------------------------

export interface WebhookEventRow {
  id: number;
  provider: string;
  externalEventId: string;
  eventType: string;
  payload: string;
  status: 'accepted' | 'duplicate';
  receivedAt: string;
}

export type JobStatus = 'queued' | 'running' | 'succeeded' | 'dead';

export interface JobRow {
  id: number;
  type: string;
  payload: string;
  status: JobStatus;
  attempts: number;
  maxAttempts: number;
  nextRetryAt: number;
  lastError: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface DeadLetterRow {
  id: number;
  jobId: number;
  type: string;
  payload: string;
  error: string;
  attempts: number;
  diedAt: string;
  retriedAt: string | null;
}

// ---- Mappers -----------------------------------------------------------------

interface WebhookEventDbRow {
  id: number;
  provider: string;
  external_event_id: string;
  event_type: string;
  payload: string;
  status: string;
  received_at: string;
}

function toEvent(row: WebhookEventDbRow): WebhookEventRow {
  return {
    id: row.id,
    provider: row.provider,
    externalEventId: row.external_event_id,
    eventType: row.event_type,
    payload: row.payload,
    status: row.status === 'duplicate' ? 'duplicate' : 'accepted',
    receivedAt: row.received_at,
  };
}

interface JobDbRow {
  id: number;
  type: string;
  payload: string;
  status: string;
  attempts: number;
  max_attempts: number;
  next_retry_at: number;
  last_error: string | null;
  created_at: string;
  updated_at: string;
}

function toJob(row: JobDbRow): JobRow {
  return {
    id: row.id,
    type: row.type,
    payload: row.payload,
    status: row.status as JobStatus,
    attempts: row.attempts,
    maxAttempts: row.max_attempts,
    nextRetryAt: row.next_retry_at,
    lastError: row.last_error,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

interface DeadLetterDbRow {
  id: number;
  job_id: number;
  type: string;
  payload: string;
  error: string;
  attempts: number;
  died_at: string;
  retried_at: string | null;
}

function toDeadLetter(row: DeadLetterDbRow): DeadLetterRow {
  return {
    id: row.id,
    jobId: row.job_id,
    type: row.type,
    payload: row.payload,
    error: row.error,
    attempts: row.attempts,
    diedAt: row.died_at,
    retriedAt: row.retried_at,
  };
}

// ---- Repositories --------------------------------------------------------------

/**
 * Idempotency ledger for inbound webhooks. The UNIQUE(provider, external_id)
 * constraint is what makes redelivered events safe.
 */
export class WebhookEventsRepository {
  constructor(private readonly db: SqliteDatabase) {}

  /**
   * Records an inbound event. Returns `false` when the same provider event id
   * was already seen (i.e. this delivery is a duplicate and must be ignored).
   */
  record(params: {
    provider: string;
    externalEventId: string;
    eventType: string;
    payload: unknown;
  }): boolean {
    const result = this.db
      .prepare(
        `INSERT INTO webhook_events
           (provider, external_event_id, event_type, payload, status, received_at)
         VALUES (@provider, @externalEventId, @eventType, @payload, 'accepted', @receivedAt)
         ON CONFLICT (provider, external_event_id) DO NOTHING`,
      )
      .run({
        provider: params.provider,
        externalEventId: params.externalEventId,
        eventType: params.eventType,
        payload: JSON.stringify(params.payload),
        receivedAt: new Date().toISOString(),
      });
    return result.changes === 1;
  }

  listRecent(limit = 50): WebhookEventRow[] {
    const rows = this.db
      .prepare(
        `SELECT * FROM webhook_events ORDER BY id DESC LIMIT ?`,
      )
      .all(limit) as WebhookEventDbRow[];
    return rows.map(toEvent);
  }
}

/** Persistent job queue with at-least-once delivery semantics. */
export class JobsRepository {
  constructor(private readonly db: SqliteDatabase) {}

  enqueue(
    type: string,
    payload: unknown,
    options: { maxAttempts: number; runAtMs?: number } = { maxAttempts: 5 },
  ): JobRow {
    const now = Date.now();
    const nowIso = new Date().toISOString();
    const result = this.db
      .prepare(
        `INSERT INTO jobs (type, payload, status, attempts, max_attempts, next_retry_at, created_at, updated_at)
         VALUES (@type, @payload, 'queued', 0, @maxAttempts, @runAt, @nowIso, @nowIso)`,
      )
      .run({
        type,
        payload: JSON.stringify(payload),
        maxAttempts: options.maxAttempts,
        runAt: options.runAtMs ?? now,
        nowIso,
      });
    return this.get(Number(result.lastInsertRowid))!;
  }

  get(id: number): JobRow | null {
    const row = this.db.prepare(`SELECT * FROM jobs WHERE id = ?`).get(id) as
      | JobDbRow
      | undefined;
    return row ? toJob(row) : null;
  }

  /**
   * Atomically claims the oldest due job for processing. The conditional
   * UPDATE (status must still be 'queued') keeps this safe even if two
   * runners poll concurrently.
   */
  claimNextDue(nowMs = Date.now()): JobRow | null {
    const candidate = this.db
      .prepare(
        `SELECT id FROM jobs
         WHERE status = 'queued' AND next_retry_at <= @nowMs
         ORDER BY next_retry_at ASC, id ASC LIMIT 1`,
      )
      .get({ nowMs }) as { id: number } | undefined;
    if (!candidate) return null;

    const claimed = this.db
      .prepare(`UPDATE jobs SET status = 'running', updated_at = @nowIso WHERE id = @id AND status = 'queued'`)
      .run({ id: candidate.id, nowIso: new Date().toISOString() });
    return claimed.changes === 1 ? this.get(candidate.id) : null;
  }

  markSucceeded(id: number): void {
    this.db
      .prepare(`UPDATE jobs SET status = 'succeeded', last_error = NULL, updated_at = @nowIso WHERE id = @id`)
      .run({ id, nowIso: new Date().toISOString() });
  }

  /** Re-queues a failed job for another attempt at [nextRetryAtMs]. */
  requeueForRetry(id: number, error: string, nextRetryAtMs: number): void {
    this.db
      .prepare(
        `UPDATE jobs
         SET status = 'queued', attempts = attempts + 1, last_error = @error,
             next_retry_at = @nextRetryAtMs, updated_at = @nowIso
         WHERE id = @id`,
      )
      .run({ id, error, nextRetryAtMs, nowIso: new Date().toISOString() });
  }

  markDead(id: number, error: string): void {
    this.db
      .prepare(
        `UPDATE jobs
         SET status = 'dead', attempts = attempts + 1, last_error = @error, updated_at = @nowIso
         WHERE id = @id`,
      )
      .run({ id, error, nowIso: new Date().toISOString() });
  }

  /** Admin: reset a dead/failed job so the runner picks it up immediately. */
  resetToQueued(id: number): boolean {
    const result = this.db
      .prepare(
        `UPDATE jobs
         SET status = 'queued', attempts = 0, last_error = NULL, next_retry_at = @nowMs, updated_at = @nowIso
         WHERE id = @id`,
      )
      .run({ id, nowMs: Date.now(), nowIso: new Date().toISOString() });
    return result.changes === 1;
  }

  listRecent(limit = 50): JobRow[] {
    const rows = this.db
      .prepare(`SELECT * FROM jobs ORDER BY id DESC LIMIT ?`)
      .all(limit) as JobDbRow[];
    return rows.map(toJob);
  }

  countByStatus(): Record<JobStatus, number> {
    const rows = this.db
      .prepare(`SELECT status, COUNT(*) as count FROM jobs GROUP BY status`)
      .all() as { status: JobStatus; count: number }[];
    const counts: Record<JobStatus, number> = { queued: 0, running: 0, succeeded: 0, dead: 0 };
    for (const row of rows) counts[row.status] = row.count;
    return counts;
  }
}

/** Failed jobs whose retries were exhausted; supports manual retry. */
export class DeadLetterRepository {
  constructor(private readonly db: SqliteDatabase) {}

  insert(job: JobRow, error: string): number {
    const result = this.db
      .prepare(
        `INSERT INTO dead_letters (job_id, type, payload, error, attempts, died_at)
         VALUES (@jobId, @type, @payload, @error, @attempts, @diedAt)`,
      )
      .run({
        jobId: job.id,
        type: job.type,
        payload: job.payload,
        error,
        attempts: job.attempts,
        diedAt: new Date().toISOString(),
      });
    return Number(result.lastInsertRowid);
  }

  get(id: number): DeadLetterRow | null {
    const row = this.db.prepare(`SELECT * FROM dead_letters WHERE id = ?`).get(id) as
      | DeadLetterDbRow
      | undefined;
    return row ? toDeadLetter(row) : null;
  }

  markRetried(id: number): void {
    this.db
      .prepare(`UPDATE dead_letters SET retried_at = @nowIso WHERE id = @id`)
      .run({ id, nowIso: new Date().toISOString() });
  }

  listRecent(limit = 50): DeadLetterRow[] {
    const rows = this.db
      .prepare(`SELECT * FROM dead_letters ORDER BY id DESC LIMIT ?`)
      .all(limit) as DeadLetterDbRow[];
    return rows.map(toDeadLetter);
  }
}

/** Per-record dedupe ledger used by the scheduled Airtable -> Sheets pull. */
export class SyncLedgerRepository {
  constructor(private readonly db: SqliteDatabase) {}

  /** Returns true only for records never synced before. */
  tryClaim(source: string, recordId: string): boolean {
    const result = this.db
      .prepare(
        `INSERT INTO sync_ledger (source, record_id, synced_at)
         VALUES (@source, @recordId, @syncedAt)
         ON CONFLICT (source, record_id) DO NOTHING`,
      )
      .run({ source, recordId, syncedAt: new Date().toISOString() });
    return result.changes === 1;
  }

  /** Rolls a claim back so a failed step runs again on the next attempt. */
  release(source: string, recordId: string): void {
    this.db
      .prepare(`DELETE FROM sync_ledger WHERE source = @source AND record_id = @recordId`)
      .run({ source, recordId });
  }

  count(source: string): number {
    const row = this.db
      .prepare(`SELECT COUNT(*) as count FROM sync_ledger WHERE source = ?`)
      .get(source) as { count: number };
    return row.count;
  }
}

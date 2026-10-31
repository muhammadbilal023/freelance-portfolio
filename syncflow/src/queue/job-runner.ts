import type { Logger } from 'pino';
import { RateLimitError } from '../utils/api-error.js';
import { computeBackoffMs, type BackoffOptions } from './backoff.js';
import type { DeadLetterRepository, JobsRepository, JobRow } from '../db/repositories.js';

/** A unit of async work. Payload is the parsed JSON stored with the job. */
export type JobHandler = (payload: unknown) => Promise<void>;

export type JobRegistry = Map<string, JobHandler>;

/** Errors that should never be retried (e.g. no handler registered). */
export class NonRetryableJobError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NonRetryableJobError';
  }
}

export interface JobRunnerOptions {
  pollIntervalMs: number;
  backoff: BackoffOptions;
}

export interface JobRunnerDeps {
  jobs: JobsRepository;
  deadLetters: DeadLetterRepository;
  registry: JobRegistry;
  logger: Logger;
  options: JobRunnerOptions;
}

/**
 * Polls the jobs table and executes due jobs with at-least-once semantics:
 * a job that fails is re-queued with exponential backoff until its attempts
 * are exhausted, then parked in the dead-letter table for manual retry.
 */
export class JobRunner {
  private timer: NodeJS.Timeout | null = null;

  constructor(private readonly deps: JobRunnerDeps) {}

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => {
      this.pollOnce().catch((err: unknown) => {
        this.deps.logger.error({ err }, 'job poll loop crashed');
      });
    }, this.deps.options.pollIntervalMs);
    // Don't keep the process alive just for the poll loop.
    this.timer.unref?.();
    this.deps.logger.info(
      { pollIntervalMs: this.deps.options.pollIntervalMs },
      'job runner started',
    );
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  /** Claims and processes one due job. Returns true when work was done. */
  async pollOnce(): Promise<boolean> {
    const job = this.deps.jobs.claimNextDue();
    if (!job) return false;
    await this.processJob(job);
    return true;
  }

  /** Drains everything currently due — used by tests and shutdown. */
  async drain(): Promise<number> {
    let processed = 0;
    while (await this.pollOnce()) processed++;
    return processed;
  }

  private async processJob(job: JobRow): Promise<void> {
    const { jobs, deadLetters, registry, logger, options } = this.deps;
    const handler = registry.get(job.type);

    try {
      if (!handler) {
        throw new NonRetryableJobError(`No handler registered for job type "${job.type}"`);
      }
      await handler(JSON.parse(job.payload) as unknown);
      jobs.markSucceeded(job.id);
      logger.info({ jobId: job.id, type: job.type, attempts: job.attempts }, 'job succeeded');
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const willExhaust = job.attempts + 1 >= job.maxAttempts;
      const retryable = !(err instanceof NonRetryableJobError);

      if (willExhaust || !retryable) {
        jobs.markDead(job.id, message);
        const updated = jobs.get(job.id)!;
        deadLetters.insert(updated, message);
        logger.error(
          { jobId: job.id, type: job.type, attempts: updated.attempts, err },
          'job dead-lettered',
        );
        return;
      }

      // Honour provider rate limits: never retry sooner than they asked.
      const backoff = computeBackoffMs(job.attempts + 1, options.backoff);
      const retryAfter = err instanceof RateLimitError ? err.retryAfterMs : 0;
      const nextRetryAt = Date.now() + Math.max(backoff, retryAfter);

      jobs.requeueForRetry(job.id, message, nextRetryAt);
      logger.warn(
        { jobId: job.id, type: job.type, attempt: job.attempts + 1, nextRetryAt, err },
        'job failed, scheduled for retry',
      );
    }
  }
}

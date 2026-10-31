import { describe, expect, it } from 'vitest';
import { RateLimitError } from '../src/utils/api-error.js';
import { computeBackoffMs } from '../src/queue/backoff.js';
import { buildTestApp } from './helpers/test-app.js';

/** Makes a re-queued job immediately due so tests never sleep. */
function makeJobDue(app: ReturnType<typeof buildTestApp>, jobId: number): void {
  app.db.prepare(`UPDATE jobs SET next_retry_at = 0 WHERE id = ?`).run(jobId);
}

describe('computeBackoffMs', () => {
  const options = { baseMs: 1000, maxMs: 60_000 };

  it('grows exponentially with the attempt number', () => {
    // random() = 1 gives the full exponential delay (equal jitter upper bound)
    expect(computeBackoffMs(1, options, () => 1)).toBe(1000);
    expect(computeBackoffMs(2, options, () => 1)).toBe(2000);
    expect(computeBackoffMs(3, options, () => 1)).toBe(4000);
    expect(computeBackoffMs(4, options, () => 1)).toBe(8000);
  });

  it('halves the delay when jitter rolls zero', () => {
    expect(computeBackoffMs(1, options, () => 0)).toBe(500);
    expect(computeBackoffMs(3, options, () => 0)).toBe(2000);
  });

  it('caps at maxMs', () => {
    expect(computeBackoffMs(20, options, () => 1)).toBe(60_000);
  });

  it('rejects attempts below 1', () => {
    expect(() => computeBackoffMs(0, options)).toThrow(RangeError);
  });
});

describe('JobRunner retry behaviour', () => {
  it('marks a successful job as succeeded', async () => {
    const app = buildTestApp();
    const calls: unknown[] = [];
    app.registry.set('test.ok', (payload) => {
      calls.push(payload);
      return Promise.resolve();
    });
    const job = app.jobs.enqueue('test.ok', { hello: 'world' }, { maxAttempts: 3 });

    await app.runner.pollOnce();

    expect(calls).toEqual([{ hello: 'world' }]);
    expect(app.jobs.get(job.id)!.status).toBe('succeeded');
  });

  it('re-queues a failed job with incremented attempts and a future retry time', async () => {
    const app = buildTestApp();
    app.registry.set('test.fail', () => Promise.reject(new Error('provider exploded')));
    const job = app.jobs.enqueue('test.fail', {}, { maxAttempts: 3 });

    const before = Date.now();
    await app.runner.pollOnce();
    const after = Date.now();

    const updated = app.jobs.get(job.id)!;
    expect(updated.status).toBe('queued');
    expect(updated.attempts).toBe(1);
    expect(updated.lastError).toBe('provider exploded');
    // backoff for attempt 1: between base/2 and base (1000ms) — never immediate
    expect(updated.nextRetryAt).toBeGreaterThanOrEqual(before + 500);
    expect(updated.nextRetryAt).toBeLessThanOrEqual(after + 1000);

    // Not due yet: polling again does nothing.
    expect(await app.runner.pollOnce()).toBe(false);
  });

  it('dead-letters a job once max attempts are exhausted', async () => {
    const app = buildTestApp();
    let runs = 0;
    app.registry.set('test.always-fails', () => {
      runs++;
      return Promise.reject(new Error('still broken'));
    });
    const job = app.jobs.enqueue('test.always-fails', {}, { maxAttempts: 3 });

    for (let attempt = 0; attempt < 3; attempt++) {
      makeJobDue(app, job.id);
      await app.runner.pollOnce();
    }

    const final = app.jobs.get(job.id)!;
    expect(runs).toBe(3);
    expect(final.status).toBe('dead');
    expect(final.attempts).toBe(3);

    const deadLetters = app.deadLetters.listRecent();
    expect(deadLetters).toHaveLength(1);
    expect(deadLetters[0]).toMatchObject({
      jobId: job.id,
      type: 'test.always-fails',
      error: 'still broken',
      attempts: 3,
      retriedAt: null,
    });
  });

  it('dead-letters immediately for an unknown job type (not retryable)', async () => {
    const app = buildTestApp();
    const job = app.jobs.enqueue('test.no-handler', {}, { maxAttempts: 5 });

    await app.runner.pollOnce();

    expect(app.jobs.get(job.id)!.status).toBe('dead');
    expect(app.jobs.get(job.id)!.attempts).toBe(1);
    expect(app.deadLetters.listRecent()[0]!.error).toContain('No handler registered');
  });

  it('honours RateLimitError.retryAfterMs over the computed backoff', async () => {
    const app = buildTestApp();
    app.registry.set('test.rate-limited', () => Promise.reject(new RateLimitError(120_000)));
    const job = app.jobs.enqueue('test.rate-limited', {}, { maxAttempts: 3 });

    const before = Date.now();
    await app.runner.pollOnce();

    const updated = app.jobs.get(job.id)!;
    expect(updated.status).toBe('queued');
    // The provider asked for 120s — longer than the 1s base backoff.
    expect(updated.nextRetryAt).toBeGreaterThanOrEqual(before + 120_000);
  });

  it('drain processes every job that is currently due', async () => {
    const app = buildTestApp();
    const executed: string[] = [];
    app.registry.set('test.track', (payload) => {
      executed.push((payload as { name: string }).name);
      return Promise.resolve();
    });
    app.jobs.enqueue('test.track', { name: 'a' }, { maxAttempts: 1 });
    app.jobs.enqueue('test.track', { name: 'b' }, { maxAttempts: 1 });

    const processed = await app.runner.drain();

    expect(processed).toBe(2);
    expect(executed.sort()).toEqual(['a', 'b']);
  });
});

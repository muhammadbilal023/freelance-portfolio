import { fileURLToPath } from 'node:url';
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { buildTestApp } from './helpers/test-app.js';

interface ErrorBody {
  error: { code: string; message: string };
}

interface JobListBody {
  jobs: { id: number; type: string; status: string }[];
  counts: Record<string, number>;
}

interface DeadLetterListBody {
  deadLetters: { id: number; type: string; error: string; retriedAt: string | null }[];
}

interface EventListBody {
  events: { id: number; provider: string; externalEventId: string; status: string }[];
}

describe('GET /health', () => {
  it('reports ok with a queue summary', async () => {
    const app = buildTestApp();

    const res = await request(app.app).get('/health');

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      status: 'ok',
      queue: { queued: 0, running: 0, succeeded: 0, dead: 0 },
    });
  });
});

describe('admin API', () => {
  it('lists webhook events recorded by the repository', async () => {
    const app = buildTestApp();
    app.events.record({
      provider: 'stripe',
      externalEventId: 'evt_admin_1',
      eventType: 'payment_intent.succeeded',
      payload: { test: true },
    });

    const res = await request(app.app).get('/admin/api/events');
    const body = res.body as EventListBody;

    expect(res.status).toBe(200);
    expect(body.events[0]).toMatchObject({
      provider: 'stripe',
      externalEventId: 'evt_admin_1',
      status: 'accepted',
    });
  });

  it('lists jobs with status counts', async () => {
    const app = buildTestApp();
    app.jobs.enqueue('demo.job', { n: 1 }, { maxAttempts: 3 });

    const res = await request(app.app).get('/admin/api/jobs');
    const body = res.body as JobListBody;

    expect(body.jobs).toHaveLength(1);
    expect(body.jobs[0]!.status).toBe('queued');
    expect(body.counts.queued).toBe(1);
  });

  it('re-queues a job via POST /admin/api/jobs/:id/retry', async () => {
    const app = buildTestApp();
    app.registry.set('demo.dead', () => Promise.reject(new Error('boom')));
    const job = app.jobs.enqueue('demo.dead', {}, { maxAttempts: 1 });
    await app.runner.pollOnce(); // exhausts attempts -> dead
    expect(app.jobs.get(job.id)!.status).toBe('dead');

    const res = await request(app.app).post(`/admin/api/jobs/${job.id}/retry`);

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ retried: true, jobId: job.id });
    expect(app.jobs.get(job.id)!.status).toBe('queued');
    expect(app.jobs.get(job.id)!.attempts).toBe(0);
  });

  it('retries a dead letter by enqueueing a fresh job and marking it retried', async () => {
    const app = buildTestApp();
    app.registry.set('demo.dlq', () => Promise.reject(new Error('nope')));
    const job = app.jobs.enqueue('demo.dlq', { order: 42 }, { maxAttempts: 1 });
    await app.runner.pollOnce();

    const listRes = await request(app.app).get('/admin/api/dead-letters');
    const deadLetters = (listRes.body as DeadLetterListBody).deadLetters;
    expect(deadLetters).toHaveLength(1);

    const retryRes = await request(app.app).post(`/admin/api/dead-letters/${deadLetters[0]!.id}/retry`);

    expect(retryRes.status).toBe(200);
    const { jobId: newJobId } = retryRes.body as { jobId: number };
    expect(newJobId).not.toBe(job.id);

    const newJob = app.jobs.get(newJobId)!;
    expect(newJob.status).toBe('queued');
    expect(JSON.parse(newJob.payload)).toEqual({ order: 42 });
    expect(app.deadLetters.get(deadLetters[0]!.id)!.retriedAt).not.toBeNull();
  });

  it('returns 404 for an unknown job id', async () => {
    const app = buildTestApp();

    const res = await request(app.app).post('/admin/api/jobs/9999/retry');

    expect(res.status).toBe(404);
    expect((res.body as ErrorBody).error.code).toBe('not_found');
  });

  it('returns 400 for a malformed id', async () => {
    const app = buildTestApp();

    const res = await request(app.app).post('/admin/api/jobs/abc/retry');

    expect(res.status).toBe(400);
    expect((res.body as ErrorBody).error.code).toBe('invalid_id');
  });

  it('returns the standard error envelope for unknown routes', async () => {
    const app = buildTestApp();

    const res = await request(app.app).get('/admin/api/nope');

    expect(res.status).toBe(404);
    expect((res.body as ErrorBody).error).toMatchObject({ code: 'not_found' });
  });

  it('serves the admin dashboard page', async () => {
    const app = buildTestApp({
      publicDir: fileURLToPath(new URL('../public', import.meta.url)),
    });

    const res = await request(app.app).get('/admin/index.html');

    expect(res.status).toBe(200);
    expect(res.text).toContain('SyncFlow');
  });
});

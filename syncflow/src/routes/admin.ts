import express, { Router } from 'express';
import type {
  DeadLetterRepository,
  JobsRepository,
  WebhookEventsRepository,
} from '../db/repositories.js';
import { ApiError } from '../utils/api-error.js';

export interface AdminDeps {
  events: WebhookEventsRepository;
  jobs: JobsRepository;
  deadLetters: DeadLetterRepository;
  maxAttempts: number;
}

function parseLimit(raw: unknown): number {
  const limit = Number(raw ?? 50);
  if (!Number.isInteger(limit) || limit < 1 || limit > 200) return 50;
  return limit;
}

function parseId(raw: string): number {
  const id = Number(raw);
  if (!Number.isInteger(id) || id < 1) {
    throw ApiError.badRequest('invalid_id', 'Id must be a positive integer');
  }
  return id;
}

/** JSON API consumed by the static admin dashboard (public/admin). */
export function createAdminRouter(deps: AdminDeps): Router {
  const router = Router();
  router.use(express.json());

  router.get('/events', (req, res) => {
    res.json({ events: deps.events.listRecent(parseLimit(req.query.limit)) });
  });

  router.get('/jobs', (req, res) => {
    res.json({
      jobs: deps.jobs.listRecent(parseLimit(req.query.limit)),
      counts: deps.jobs.countByStatus(),
    });
  });

  router.get('/dead-letters', (req, res) => {
    res.json({ deadLetters: deps.deadLetters.listRecent(parseLimit(req.query.limit)) });
  });

  /** Re-queue an existing job (typically a dead one) from scratch. */
  router.post('/jobs/:id/retry', (req, res) => {
    const id = parseId(req.params.id);
    const job = deps.jobs.get(id);
    if (!job) throw ApiError.notFound(`Job ${id} not found`);

    deps.jobs.resetToQueued(id);
    res.json({ retried: true, jobId: id });
  });

  /** Re-run a dead-lettered job by enqueueing a fresh copy of its payload. */
  router.post('/dead-letters/:id/retry', (req, res) => {
    const id = parseId(req.params.id);
    const deadLetter = deps.deadLetters.get(id);
    if (!deadLetter) throw ApiError.notFound(`Dead letter ${id} not found`);

    const job = deps.jobs.enqueue(
      deadLetter.type,
      JSON.parse(deadLetter.payload) as unknown,
      { maxAttempts: deps.maxAttempts },
    );
    deps.deadLetters.markRetried(id);
    res.json({ retried: true, jobId: job.id, deadLetterId: id });
  });

  return router;
}

import { Router } from 'express';
import type { JobsRepository } from '../db/repositories.js';

/** Liveness/readiness probe with a queue summary for dashboards and Docker. */
export function createHealthRouter(jobs: JobsRepository): Router {
  const router = Router();

  router.get('/', (_req, res) => {
    res.json({
      status: 'ok',
      uptimeSeconds: Math.round(process.uptime()),
      queue: jobs.countByStatus(),
    });
  });

  return router;
}

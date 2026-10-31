import path from 'node:path';
import express, { type Express } from 'express';
import helmet from 'helmet';
import { pinoHttp } from 'pino-http';
import type { Logger } from 'pino';
import type { AppConfig } from './config.js';
import {
  DeadLetterRepository,
  JobsRepository,
  SyncLedgerRepository,
  WebhookEventsRepository,
} from './db/repositories.js';
import type { SqliteDatabase } from './db/database.js';
import { buildJobRegistry } from './flows/registry.js';
import { AIRTABLE_PULL_JOB } from './flows/airtable-pull.flow.js';
import { createIntegrations } from './integrations/factory.js';
import { HmacShopifyWebhookVerifier } from './integrations/shopify-verifier.js';
import { SdkStripeWebhookVerifier } from './integrations/stripe-verifier.js';
import type {
  Integrations,
  ShopifyWebhookVerifier,
  StripeWebhookVerifier,
} from './integrations/types.js';
import { createErrorHandler, notFoundHandler } from './middleware/error-handler.js';
import { JobRunner, type JobRegistry } from './queue/job-runner.js';
import { Scheduler } from './queue/scheduler.js';
import { createAdminRouter } from './routes/admin.js';
import { createHealthRouter } from './routes/health.js';
import { createWebhooksRouter } from './routes/webhooks.js';

export interface AppDependencies {
  config: AppConfig;
  logger: Logger;
  db: SqliteDatabase;
  /** Overridable for tests; defaults to the real HTTP clients / SDK verifiers. */
  integrations?: Integrations;
  stripeVerifier?: StripeWebhookVerifier | null;
  shopifyVerifier?: ShopifyWebhookVerifier | null;
  publicDir?: string;
}

export interface SyncFlowServices {
  app: Express;
  events: WebhookEventsRepository;
  jobs: JobsRepository;
  deadLetters: DeadLetterRepository;
  ledger: SyncLedgerRepository;
  registry: JobRegistry;
  runner: JobRunner;
  pullScheduler: Scheduler;
}

/**
 * Composition root: builds repositories, flows, queue and HTTP app from the
 * config. Tests pass an in-memory db plus fake integrations/verifiers and
 * get a fully wired, isolated instance back.
 */
export function buildServices(deps: AppDependencies): SyncFlowServices {
  const { config, logger, db } = deps;

  const events = new WebhookEventsRepository(db);
  const jobs = new JobsRepository(db);
  const deadLetters = new DeadLetterRepository(db);
  const ledger = new SyncLedgerRepository(db);

  const integrations = deps.integrations ?? createIntegrations(config);

  // `undefined` means "use the real verifier when credentials exist";
  // an explicit `null` (tests) means "no verifier".
  const stripeVerifier =
    deps.stripeVerifier !== undefined
      ? deps.stripeVerifier
      : config.STRIPE_WEBHOOK_SECRET
        ? new SdkStripeWebhookVerifier(config.STRIPE_WEBHOOK_SECRET)
        : null;
  const shopifyVerifier =
    deps.shopifyVerifier !== undefined
      ? deps.shopifyVerifier
      : config.SHOPIFY_HMAC_SECRET
        ? new HmacShopifyWebhookVerifier(config.SHOPIFY_HMAC_SECRET)
        : null;

  const registry = buildJobRegistry({ config, integrations, ledger });

  const runner = new JobRunner({
    jobs,
    deadLetters,
    registry,
    logger,
    options: {
      pollIntervalMs: config.JOB_POLL_INTERVAL_MS,
      backoff: { baseMs: config.BACKOFF_BASE_MS, maxMs: config.BACKOFF_MAX_MS },
    },
  });

  // Flow 3 tick: enqueue (not execute) so pulls get the same retry/DLQ
  // treatment as webhook-driven jobs.
  const pullScheduler = new Scheduler(
    'airtable-pull',
    config.AIRTABLE_PULL_INTERVAL_MS,
    () => {
      jobs.enqueue(AIRTABLE_PULL_JOB, { requestedAt: new Date().toISOString() }, {
        maxAttempts: config.JOB_MAX_ATTEMPTS,
      });
    },
    logger,
  );

  const app = express();
  app.disable('x-powered-by');
  app.use(helmet());
  app.use(pinoHttp({ logger }));

  app.use('/health', createHealthRouter(jobs));
  app.use(
    '/webhooks',
    createWebhooksRouter({ config, logger, events, jobs, stripeVerifier, shopifyVerifier }),
  );
  app.use(
    '/admin/api',
    createAdminRouter({ events, jobs, deadLetters, maxAttempts: config.JOB_MAX_ATTEMPTS }),
  );

  const publicDir = deps.publicDir ?? path.resolve(process.cwd(), 'public');
  app.use('/admin', express.static(publicDir));

  app.use(notFoundHandler);
  app.use(createErrorHandler(logger));

  return { app, events, jobs, deadLetters, ledger, registry, runner, pullScheduler };
}

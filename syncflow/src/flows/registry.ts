import type { AppConfig } from '../config.js';
import type { SyncLedgerRepository } from '../db/repositories.js';
import type { Integrations } from '../integrations/types.js';
import type { JobRegistry } from '../queue/job-runner.js';
import {
  AIRTABLE_PULL_JOB,
  createAirtablePullHandler,
} from './airtable-pull.flow.js';
import {
  SHOPIFY_ORDER_JOB,
  createShopifyOrderHandler,
} from './shopify-order.flow.js';
import {
  STRIPE_PAYMENT_JOB,
  createStripePaymentHandler,
} from './stripe-payment.flow.js';

export interface FlowDeps {
  config: AppConfig;
  integrations: Integrations;
  ledger: SyncLedgerRepository;
}

/** Maps every job type this hub knows how to execute onto its handler. */
export function buildJobRegistry({ config, integrations, ledger }: FlowDeps): JobRegistry {
  return new Map([
    [STRIPE_PAYMENT_JOB, createStripePaymentHandler(config, integrations, ledger)],
    [SHOPIFY_ORDER_JOB, createShopifyOrderHandler(config, integrations, ledger)],
    [AIRTABLE_PULL_JOB, createAirtablePullHandler(config, integrations, ledger)],
  ]);
}

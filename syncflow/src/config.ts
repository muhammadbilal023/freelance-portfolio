import { z } from 'zod';

/**
 * All integration credentials are optional: SyncFlow starts without them and
 * the affected flows fail at runtime into the dead-letter table, which is a
 * better demo/dev experience than refusing to boot.
 */
const configSchema = z.object({
  PORT: z.coerce.number().int().positive().default(8081),
  DATABASE_PATH: z.string().min(1).default('./data/syncflow.db'),

  LOG_LEVEL: z
    .enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent'])
    .default('info'),
  LOG_PRETTY: z
    .string()
    .default('false')
    .transform((v) => v === 'true'),

  // Job queue tuning
  JOB_POLL_INTERVAL_MS: z.coerce.number().int().min(50).default(1000),
  JOB_MAX_ATTEMPTS: z.coerce.number().int().min(1).max(20).default(5),
  BACKOFF_BASE_MS: z.coerce.number().int().positive().default(1000),
  BACKOFF_MAX_MS: z.coerce.number().int().positive().default(300_000),

  // Webhook signature secrets
  STRIPE_WEBHOOK_SECRET: z.string().default(''),
  SHOPIFY_HMAC_SECRET: z.string().default(''),

  // Google Sheets
  GOOGLE_SERVICE_ACCOUNT_KEY_PATH: z.string().default(''),
  PAYMENTS_SHEET_ID: z.string().default(''),
  PAYMENTS_SHEET_NAME: z.string().default('Payments'),
  AIRTABLE_MIRROR_SHEET_ID: z.string().default(''),
  AIRTABLE_MIRROR_SHEET_NAME: z.string().default('Airtable'),

  // HubSpot
  HUBSPOT_ACCESS_TOKEN: z.string().default(''),

  // Airtable
  AIRTABLE_API_KEY: z.string().default(''),
  AIRTABLE_BASE_ID: z.string().default(''),
  AIRTABLE_ORDERS_TABLE: z.string().default('Orders'),
  AIRTABLE_PULL_TABLE: z.string().default('Inbox'),

  // Slack
  SLACK_WEBHOOK_URL: z.string().default(''),

  // Flow 3 schedule
  AIRTABLE_PULL_INTERVAL_MS: z.coerce.number().int().min(10_000).default(900_000),
});

export type AppConfig = z.infer<typeof configSchema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const parsed = configSchema.safeParse(env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `${i.path.join('.')}: ${i.message}`)
      .join('; ');
    throw new Error(`Invalid configuration — ${issues}`);
  }
  return parsed.data;
}

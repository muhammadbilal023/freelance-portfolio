import { buildServices, type AppDependencies, type SyncFlowServices } from '../../src/app.js';
import { loadConfig, type AppConfig } from '../../src/config.js';
import { openDatabase, type SqliteDatabase } from '../../src/db/database.js';
import { createLogger } from '../../src/logger.js';
import type {
  AirtableClient,
  AirtableRecord,
  HubspotClient,
  HubspotDealInput,
  Integrations,
  SheetsClient,
  SlackClient,
} from '../../src/integrations/types.js';

// ---- In-memory fakes for every external integration --------------------------

export class FakeSheets implements SheetsClient {
  readonly rows: { spreadsheetId: string; sheetName: string; row: (string | number)[] }[] = [];
  failWith: Error | null = null;

  appendRow(
    spreadsheetId: string,
    sheetName: string,
    row: (string | number)[],
  ): Promise<void> {
    if (this.failWith) return Promise.reject(this.failWith);
    this.rows.push({ spreadsheetId, sheetName, row });
    return Promise.resolve();
  }
}

export class FakeHubspot implements HubspotClient {
  readonly deals: HubspotDealInput[] = [];
  failWith: Error | null = null;

  upsertContactWithDeal(input: HubspotDealInput): Promise<void> {
    if (this.failWith) return Promise.reject(this.failWith);
    this.deals.push(input);
    return Promise.resolve();
  }
}

export class FakeAirtable implements AirtableClient {
  records: AirtableRecord[] = [];
  readonly created: { baseId: string; table: string; fields: Record<string, unknown> }[] = [];
  failWith: Error | null = null;
  private nextId = 1;

  listRecords(): Promise<AirtableRecord[]> {
    if (this.failWith) return Promise.reject(this.failWith);
    return Promise.resolve([...this.records]);
  }

  createRecord(
    baseId: string,
    table: string,
    fields: Record<string, unknown>,
  ): Promise<string> {
    if (this.failWith) return Promise.reject(this.failWith);
    this.created.push({ baseId, table, fields });
    return Promise.resolve(`rec_fake_${this.nextId++}`);
  }
}

export class FakeSlack implements SlackClient {
  readonly messages: string[] = [];
  failWith: Error | null = null;

  postMessage(text: string): Promise<void> {
    if (this.failWith) return Promise.reject(this.failWith);
    this.messages.push(text);
    return Promise.resolve();
  }
}

export interface FakeIntegrations extends Integrations {
  sheets: FakeSheets;
  hubspot: FakeHubspot;
  airtable: FakeAirtable;
  slack: FakeSlack;
}

export function createFakeIntegrations(): FakeIntegrations {
  return {
    sheets: new FakeSheets(),
    hubspot: new FakeHubspot(),
    airtable: new FakeAirtable(),
    slack: new FakeSlack(),
  };
}

// ---- Test application ----------------------------------------------------------

export interface TestApp extends SyncFlowServices {
  config: AppConfig;
  db: SqliteDatabase;
  fakes: FakeIntegrations;
}

/**
 * Fully wired SyncFlow instance on an in-memory database with fake
 * integrations. Webhook verifiers are the REAL ones (SDK / HMAC) so
 * signature tests exercise production code paths.
 */
export function buildTestApp(overrides: Partial<AppDependencies> = {}): TestApp {
  const config = loadConfig({
    PORT: '8081',
    DATABASE_PATH: ':memory:',
    LOG_LEVEL: 'silent',
    STRIPE_WEBHOOK_SECRET: 'whsec_test_secret',
    SHOPIFY_HMAC_SECRET: 'shopify_test_secret',
    JOB_MAX_ATTEMPTS: '3',
    BACKOFF_BASE_MS: '1000',
    BACKOFF_MAX_MS: '60000',
    PAYMENTS_SHEET_ID: 'sheet_payments',
    AIRTABLE_MIRROR_SHEET_ID: 'sheet_mirror',
    AIRTABLE_BASE_ID: 'appTest',
  });
  const logger = createLogger(config);
  const db = openDatabase(':memory:');
  const fakes = createFakeIntegrations();

  const services = buildServices({
    config,
    logger,
    db,
    integrations: fakes,
    ...overrides,
  });

  return { ...services, config, db, fakes };
}

// ---- Webhook payload helpers ------------------------------------------------------

export const STRIPE_EVENT_OBJECT = {
  id: 'pi_test_123',
  object: 'payment_intent',
  amount: 4500,
  currency: 'usd',
  receipt_email: 'client@example.com',
  charges: {
    data: [
      {
        billing_details: { name: 'Test Client', email: 'client@example.com' },
      },
    ],
  },
};

export function stripeEventBody(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    id: 'evt_test_123',
    object: 'event',
    type: 'payment_intent.succeeded',
    data: { object: STRIPE_EVENT_OBJECT },
    ...overrides,
  });
}

export const SHOPIFY_ORDER_BODY = {
  id: 5001,
  order_number: 1001,
  customer: { first_name: 'Ada', last_name: 'Lovelace', email: 'ada@example.com' },
  total_price: '89.99',
  currency: 'EUR',
  financial_status: 'paid',
  line_items: [{ id: 1 }, { id: 2 }],
  created_at: '2026-10-30T12:00:00Z',
};

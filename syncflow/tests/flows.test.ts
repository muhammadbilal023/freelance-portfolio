import { describe, expect, it } from 'vitest';
import {
  AIRTABLE_PULL_JOB,
} from '../src/flows/airtable-pull.flow.js';
import {
  SHOPIFY_ORDER_JOB,
  normalizeShopifyOrder,
} from '../src/flows/shopify-order.flow.js';
import {
  STRIPE_PAYMENT_JOB,
  parseStripePaymentEvent,
} from '../src/flows/stripe-payment.flow.js';
import type { AirtableRecord } from '../src/integrations/types.js';
import { buildTestApp, SHOPIFY_ORDER_BODY, STRIPE_EVENT_OBJECT } from './helpers/test-app.js';

const STRIPE_JOB_PAYLOAD = {
  paymentIntentId: 'pi_test_123',
  amountCents: 4500,
  currency: 'USD',
  customerEmail: 'client@example.com',
  customerName: 'Test Client',
  paidAt: '2026-10-30T12:00:00Z',
};

describe('parseStripePaymentEvent', () => {
  it('maps a payment_intent.succeeded event onto the job payload', () => {
    const result = parseStripePaymentEvent({
      id: 'evt_1',
      type: 'payment_intent.succeeded',
      data: STRIPE_EVENT_OBJECT,
    });

    expect(result).toMatchObject({
      paymentIntentId: 'pi_test_123',
      amountCents: 4500,
      currency: 'USD',
      customerEmail: 'client@example.com',
      customerName: 'Test Client',
    });
  });

  it('returns null for other event types', () => {
    expect(
      parseStripePaymentEvent({
        id: 'evt_2',
        type: 'charge.refunded',
        data: STRIPE_EVENT_OBJECT,
      }),
    ).toBeNull();
  });

  it('returns null when required fields are missing', () => {
    expect(
      parseStripePaymentEvent({ id: 'evt_3', type: 'payment_intent.succeeded', data: {} }),
    ).toBeNull();
  });
});

describe('normalizeShopifyOrder', () => {
  it('flattens the raw webhook body', () => {
    const order = normalizeShopifyOrder(SHOPIFY_ORDER_BODY);

    expect(order).toMatchObject({
      orderId: '5001',
      orderNumber: '1001',
      customerName: 'Ada Lovelace',
      customerEmail: 'ada@example.com',
      totalPrice: '89.99',
      currency: 'EUR',
      financialStatus: 'paid',
      itemCount: 2,
    });
  });

  it('rejects a body without an order id', () => {
    expect(normalizeShopifyOrder({ total_price: '10.00' })).toBeNull();
  });
});

describe('Flow 1: stripe payment -> Sheets + HubSpot', () => {
  it('appends the payments row and creates the CRM deal', async () => {
    const app = buildTestApp();
    const handler = app.registry.get(STRIPE_PAYMENT_JOB)!;

    await handler(STRIPE_JOB_PAYLOAD);

    expect(app.fakes.sheets.rows).toHaveLength(1);
    expect(app.fakes.sheets.rows[0]).toMatchObject({
      spreadsheetId: 'sheet_payments',
      sheetName: 'Payments',
    });
    expect(app.fakes.sheets.rows[0]!.row).toContain(45); // 4500 cents -> 45
    expect(app.fakes.hubspot.deals).toEqual([
      expect.objectContaining({
        email: 'client@example.com',
        firstName: 'Test',
        lastName: 'Client',
        amount: '45.00',
        stage: 'closedwon',
      }),
    ]);
  });

  it('is idempotent per step: a retry after partial failure does not double-append', async () => {
    const app = buildTestApp();
    const handler = app.registry.get(STRIPE_PAYMENT_JOB)!;

    // HubSpot is down during the first attempt — Sheets already succeeded.
    app.fakes.hubspot.failWith = new Error('hubspot 503');
    await expect(handler(STRIPE_JOB_PAYLOAD)).rejects.toThrow('hubspot 503');
    expect(app.fakes.sheets.rows).toHaveLength(1);

    // Retry with HubSpot healthy: only the missing step runs.
    app.fakes.hubspot.failWith = null;
    await handler(STRIPE_JOB_PAYLOAD);

    expect(app.fakes.sheets.rows).toHaveLength(1);
    expect(app.fakes.hubspot.deals).toHaveLength(1);
  });

  it('skips the CRM step when no customer email is present', async () => {
    const app = buildTestApp();
    const handler = app.registry.get(STRIPE_PAYMENT_JOB)!;

    await handler({ ...STRIPE_JOB_PAYLOAD, customerEmail: '' });

    expect(app.fakes.sheets.rows).toHaveLength(1);
    expect(app.fakes.hubspot.deals).toHaveLength(0);
  });
});

describe('Flow 2: shopify order -> Airtable + Slack', () => {
  const order = normalizeShopifyOrder(SHOPIFY_ORDER_BODY)!;

  it('creates the Airtable record and posts to Slack', async () => {
    const app = buildTestApp();
    const handler = app.registry.get(SHOPIFY_ORDER_JOB)!;

    await handler(order);

    expect(app.fakes.airtable.created).toHaveLength(1);
    expect(app.fakes.airtable.created[0]).toMatchObject({ baseId: 'appTest', table: 'Orders' });
    expect(app.fakes.airtable.created[0]!.fields).toMatchObject({
      OrderId: '5001',
      Total: 89.99,
      Customer: 'Ada Lovelace',
    });
    expect(app.fakes.slack.messages[0]).toContain('New order #1001');
  });

  it('does not duplicate the record or the message on retry', async () => {
    const app = buildTestApp();
    const handler = app.registry.get(SHOPIFY_ORDER_JOB)!;

    await handler(order);
    await handler(order);

    expect(app.fakes.airtable.created).toHaveLength(1);
    expect(app.fakes.slack.messages).toHaveLength(1);
  });
});

describe('Flow 3: scheduled Airtable -> Sheets pull', () => {
  function record(id: string, fields: Record<string, unknown>): AirtableRecord {
    return { id, fields, createdTime: '2026-10-30T10:00:00Z' };
  }

  it('mirrors only records never seen before (duplicate protection)', async () => {
    const app = buildTestApp();
    const handler = app.registry.get(AIRTABLE_PULL_JOB)!;

    app.fakes.airtable.records = [record('recA', { Name: 'A' }), record('recB', { Name: 'B' })];
    await handler({ requestedAt: new Date().toISOString() });
    expect(app.fakes.sheets.rows).toHaveLength(2);

    // Second tick with one old + one new record: only the new one is appended.
    app.fakes.airtable.records = [record('recB', { Name: 'B' }), record('recC', { Name: 'C' })];
    await handler({ requestedAt: new Date().toISOString() });
    expect(app.fakes.sheets.rows).toHaveLength(3);
    expect(app.fakes.sheets.rows[2]!.row[0]).toBe('recC');
    expect(app.ledger.count('airtable-pull')).toBe(3);
  });

  it('the scheduler tick enqueues a pull job that the runner executes', async () => {
    const app = buildTestApp();
    app.fakes.airtable.records = [record('recX', { Name: 'X' })];

    await app.pullScheduler.runOnce();
    const queued = app.jobs.listRecent();
    expect(queued).toHaveLength(1);
    expect(queued[0]!.type).toBe(AIRTABLE_PULL_JOB);

    await app.runner.drain();

    expect(app.jobs.get(queued[0]!.id)!.status).toBe('succeeded');
    expect(app.fakes.sheets.rows).toHaveLength(1);
  });
});

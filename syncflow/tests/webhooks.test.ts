import crypto from 'node:crypto';
import request from 'supertest';
import Stripe from 'stripe';
import { describe, expect, it } from 'vitest';
import { STRIPE_PAYMENT_JOB } from '../src/flows/stripe-payment.flow.js';
import { SHOPIFY_ORDER_JOB } from '../src/flows/shopify-order.flow.js';
import { buildTestApp, SHOPIFY_ORDER_BODY, stripeEventBody } from './helpers/test-app.js';

const stripe = new Stripe('sk_test_unused');
const STRIPE_SECRET = 'whsec_test_secret';
const SHOPIFY_SECRET = 'shopify_test_secret';

/** Signs a payload exactly the way the Stripe CLI / dashboard does. */
function signStripe(payload: string, secret = STRIPE_SECRET): string {
  return stripe.webhooks.generateTestHeaderString({ payload, secret });
}

function signShopify(body: string, secret = SHOPIFY_SECRET): string {
  return crypto.createHmac('sha256', secret).update(body).digest('base64');
}

describe('POST /webhooks/stripe', () => {
  it('accepts a correctly signed payment_intent.succeeded and queues a job', async () => {
    const app = buildTestApp();
    const payload = stripeEventBody();
    const signature = signStripe(payload);

    const res = await request(app.app)
      .post('/webhooks/stripe')
      .set('stripe-signature', signature)
      .set('content-type', 'application/json')
      .send(payload);

    expect(res.status).toBe(202);
    expect(res.body).toMatchObject({ accepted: true });

    const job = app.jobs.get(Number((res.body as { jobId: number }).jobId))!;
    expect(job.type).toBe(STRIPE_PAYMENT_JOB);
    expect(JSON.parse(job.payload)).toMatchObject({
      paymentIntentId: 'pi_test_123',
      amountCents: 4500,
      currency: 'USD',
      customerEmail: 'client@example.com',
      customerName: 'Test Client',
    });
  });

  it('rejects a tampered body (signature no longer matches)', async () => {
    const app = buildTestApp();
    const signature = signStripe(stripeEventBody());
    const tampered = stripeEventBody().replace('4500', '9999');

    const res = await request(app.app)
      .post('/webhooks/stripe')
      .set('stripe-signature', signature)
      .set('content-type', 'application/json')
      .send(tampered);

    expect(res.status).toBe(401);
    expect(res.body).toMatchObject({ error: { code: 'invalid_signature' } });
    expect(app.jobs.listRecent()).toHaveLength(0);
  });

  it('rejects a request without a signature header', async () => {
    const app = buildTestApp();

    const res = await request(app.app)
      .post('/webhooks/stripe')
      .set('content-type', 'application/json')
      .send(stripeEventBody());

    expect(res.status).toBe(401);
    expect(res.body).toMatchObject({ error: { code: 'missing_signature' } });
  });

  it('acknowledges but ignores unsupported event types', async () => {
    const app = buildTestApp();
    const payload = stripeEventBody({ type: 'customer.created' });
    const signature = signStripe(payload);

    const res = await request(app.app)
      .post('/webhooks/stripe')
      .set('stripe-signature', signature)
      .set('content-type', 'application/json')
      .send(payload);

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ accepted: false, reason: 'event_type_not_handled' });
    expect(app.jobs.listRecent()).toHaveLength(0);
  });

  it('is idempotent: a redelivered event is marked duplicate and not re-queued', async () => {
    const app = buildTestApp();
    const payload = stripeEventBody();
    const signature = signStripe(payload);

    const first = await request(app.app)
      .post('/webhooks/stripe')
      .set('stripe-signature', signature)
      .set('content-type', 'application/json')
      .send(payload);
    const second = await request(app.app)
      .post('/webhooks/stripe')
      .set('stripe-signature', signature)
      .set('content-type', 'application/json')
      .send(payload);

    expect(first.status).toBe(202);
    expect(second.status).toBe(200);
    expect(second.body).toMatchObject({ accepted: false, reason: 'duplicate' });
    expect(app.jobs.listRecent()).toHaveLength(1);
  });
});

describe('POST /webhooks/shopify', () => {
  const orderPayload = JSON.stringify(SHOPIFY_ORDER_BODY);

  function shopifyRequest(app: ReturnType<typeof buildTestApp>, body: string, hmac: string) {
    return request(app.app)
      .post('/webhooks/shopify')
      .set('x-shopify-hmac-sha256', hmac)
      .set('x-shopify-topic', 'orders/create')
      .set('x-shopify-webhook-id', 'wh_delivery_1')
      .set('content-type', 'application/json')
      .send(body);
  }

  it('accepts a correctly signed orders/create and queues a normalised job', async () => {
    const app = buildTestApp();

    const res = await shopifyRequest(app, orderPayload, signShopify(orderPayload));

    expect(res.status).toBe(202);
    const job = app.jobs.get(Number((res.body as { jobId: number }).jobId))!;
    expect(job.type).toBe(SHOPIFY_ORDER_JOB);
    expect(JSON.parse(job.payload)).toMatchObject({
      orderId: '5001',
      orderNumber: '1001',
      customerName: 'Ada Lovelace',
      customerEmail: 'ada@example.com',
      totalPrice: '89.99',
      currency: 'EUR',
      itemCount: 2,
    });
  });

  it('rejects an invalid HMAC', async () => {
    const app = buildTestApp();

    const res = await shopifyRequest(app, orderPayload, signShopify(orderPayload, 'wrong_secret'));

    expect(res.status).toBe(401);
    expect(res.body).toMatchObject({ error: { code: 'invalid_signature' } });
    expect(app.jobs.listRecent()).toHaveLength(0);
  });

  it('rejects when the body was modified after signing', async () => {
    const app = buildTestApp();
    const hmac = signShopify(orderPayload);
    const tampered = orderPayload.replace('89.99', '0.01');

    const res = await shopifyRequest(app, tampered, hmac);

    expect(res.status).toBe(401);
  });

  it('acknowledges but ignores other topics', async () => {
    const app = buildTestApp();

    const res = await request(app.app)
      .post('/webhooks/shopify')
      .set('x-shopify-hmac-sha256', signShopify(orderPayload))
      .set('x-shopify-topic', 'products/update')
      .set('content-type', 'application/json')
      .send(orderPayload);

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ accepted: false, reason: 'topic_not_handled' });
  });

  it('is idempotent on the Shopify delivery id', async () => {
    const app = buildTestApp();
    const hmac = signShopify(orderPayload);

    const first = await shopifyRequest(app, orderPayload, hmac);
    const second = await shopifyRequest(app, orderPayload, hmac);

    expect(first.status).toBe(202);
    expect(second.body).toMatchObject({ accepted: false, reason: 'duplicate' });
    expect(app.jobs.listRecent()).toHaveLength(1);
  });

  it('rejects a payload that cannot be normalised with a 422', async () => {
    const app = buildTestApp();
    const badBody = JSON.stringify({ note: 'no order id here' });

    const res = await shopifyRequest(app, badBody, signShopify(badBody));

    expect(res.status).toBe(422);
    expect(res.body).toMatchObject({ error: { code: 'invalid_payload' } });
  });
});

describe('unconfigured webhooks', () => {
  it('returns 503 when the Stripe signing secret is missing', async () => {
    const app = buildTestApp({ stripeVerifier: null });

    const res = await request(app.app)
      .post('/webhooks/stripe')
      .set('content-type', 'application/json')
      .send(stripeEventBody());

    expect(res.status).toBe(503);
    expect(res.body).toMatchObject({ error: { code: 'not_configured' } });
  });

  it('returns 503 when the Shopify secret is missing', async () => {
    const app = buildTestApp({ shopifyVerifier: null });

    const res = await request(app.app)
      .post('/webhooks/shopify')
      .set('content-type', 'application/json')
      .send('{}');

    expect(res.status).toBe(503);
    expect(res.body).toMatchObject({ error: { code: 'not_configured' } });
  });
});

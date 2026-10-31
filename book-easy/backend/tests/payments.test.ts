import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import { buildTestApp } from './helpers/test-app.js';
import { ApiError } from '../src/utils/api-error.js';

interface ErrorBody {
  error: { code: string; message: string; details?: { field: string; message: string }[] };
}

/** Casts a supertest response body to the API's error envelope. */
function errorOf(res: { body: unknown }): ErrorBody['error'] {
  return (res.body as ErrorBody).error;
}

describe('POST /api/payments/payment-intent', () => {
  let ctx: ReturnType<typeof buildTestApp>;

  beforeEach(() => {
    ctx = buildTestApp();
  });

  it('creates a payment intent and returns the client secret', async () => {
    const res = await request(ctx.app)
      .post('/api/payments/payment-intent')
      .send({ amount: 4500, currency: 'usd', bookingId: 'booking_1' })
      .expect(201);

    expect(res.body).toEqual({
      paymentIntentId: 'pi_test_123',
      clientSecret: 'pi_test_123_secret_abc',
      status: 'requires_payment_method',
    });
    // Currency should be normalized to lowercase before reaching the gateway.
    expect(ctx.gateway.calls).toHaveLength(1);
    expect(ctx.gateway.calls[0]).toMatchObject({ amount: 4500, currency: 'usd', bookingId: 'booking_1' });
  });

  it('rejects a missing amount with a 400 validation envelope', async () => {
    const res = await request(ctx.app)
      .post('/api/payments/payment-intent')
      .send({ currency: 'usd' })
      .expect(400);

    expect(errorOf(res).code).toBe('validation_error');
    expect(errorOf(res).details).toEqual(
      expect.arrayContaining([expect.objectContaining({ field: 'amount' })]),
    );
    expect(ctx.gateway.calls).toHaveLength(0);
  });

  it('rejects fractional amounts', async () => {
    const res = await request(ctx.app)
      .post('/api/payments/payment-intent')
      .send({ amount: 12.5, currency: 'usd' })
      .expect(400);
    expect(errorOf(res).code).toBe('validation_error');
  });

  it('rejects unsupported currencies', async () => {
    await request(ctx.app)
      .post('/api/payments/payment-intent')
      .send({ amount: 100, currency: 'xxx' })
      .expect(400);
  });

  it('rejects amounts above the configured maximum', async () => {
    const res = await request(ctx.app)
      .post('/api/payments/payment-intent')
      .send({ amount: ctx.config.MAX_AMOUNT_CENTS + 1, currency: 'usd' })
      .expect(400);
    expect(errorOf(res).code).toBe('amount_too_large');
  });

  it('maps gateway failures to a 502 without leaking internals', async () => {
    ctx.gateway.nextError = new ApiError(502, 'stripe_error', 'Payment provider returned an error');
    const res = await request(ctx.app)
      .post('/api/payments/payment-intent')
      .send({ amount: 100, currency: 'usd' })
      .expect(502);
    expect(errorOf(res).code).toBe('stripe_error');
    expect(JSON.stringify(res.body)).not.toContain('stack');
  });

  it('maps unexpected errors to a generic 500', async () => {
    ctx.gateway.nextError = new Error('boom: secret internal detail');
    const res = await request(ctx.app)
      .post('/api/payments/payment-intent')
      .send({ amount: 100, currency: 'usd' })
      .expect(500);
    expect(errorOf(res).code).toBe('internal_error');
    expect(errorOf(res).message).not.toContain('secret internal detail');
  });
});

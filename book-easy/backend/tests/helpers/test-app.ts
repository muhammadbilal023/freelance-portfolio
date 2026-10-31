import pino from 'pino';
import { createApp } from '../../src/app.js';
import { loadConfig, type AppConfig } from '../../src/config.js';
import type { PaymentGateway, PaymentIntentResult } from '../../src/services/stripe.service.js';
import type { CreatePaymentIntentInput } from '../../src/schemas/payment.schema.js';

/**
 * In-memory gateway double. Records every call and lets each test script
 * the result or the failure it wants to simulate.
 */
export class FakePaymentGateway implements PaymentGateway {
  readonly calls: CreatePaymentIntentInput[] = [];
  result: PaymentIntentResult = {
    id: 'pi_test_123',
    clientSecret: 'pi_test_123_secret_abc',
    status: 'requires_payment_method',
  };
  nextError: Error | null = null;

  createPaymentIntent(input: CreatePaymentIntentInput): Promise<PaymentIntentResult> {
    this.calls.push(input);
    if (this.nextError) return Promise.reject(this.nextError);
    return Promise.resolve(this.result);
  }
}

export function buildTestApp(): { config: AppConfig; gateway: FakePaymentGateway; app: ReturnType<typeof createApp> } {
  const config = loadConfig({
    STRIPE_SECRET_KEY: 'sk_test_fake_key_for_tests',
    NODE_ENV: 'test',
    LOG_LEVEL: 'fatal',
  });
  const gateway = new FakePaymentGateway();
  const logger = pino({ level: 'silent' });
  const app = createApp({ config, logger, gateway });
  return { config, gateway, app };
}

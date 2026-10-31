import Stripe from 'stripe';
import type { Logger } from 'pino';
import { ApiError } from '../utils/api-error.js';
import type { CreatePaymentIntentInput } from '../schemas/payment.schema.js';

export interface PaymentIntentResult {
  id: string;
  clientSecret: string;
  status: string;
}

/** Abstraction over Stripe so controllers can be tested with a fake gateway. */
export interface PaymentGateway {
  createPaymentIntent(input: CreatePaymentIntentInput): Promise<PaymentIntentResult>;
}

export class StripePaymentGateway implements PaymentGateway {
  private readonly stripe: Stripe;

  constructor(
    secretKey: string,
    private readonly maxAmountCents: number,
    private readonly logger: Logger,
  ) {
    this.stripe = new Stripe(secretKey, { apiVersion: '2024-06-20' });
  }

  async createPaymentIntent(input: CreatePaymentIntentInput): Promise<PaymentIntentResult> {
    if (input.amount > this.maxAmountCents) {
      throw ApiError.badRequest(
        'amount_too_large',
        `amount must not exceed ${this.maxAmountCents} minor units`,
      );
    }

    try {
      const intent = await this.stripe.paymentIntents.create({
        amount: input.amount,
        currency: input.currency,
        automatic_payment_methods: { enabled: true },
        metadata: {
          ...(input.bookingId ? { bookingId: input.bookingId } : {}),
          ...(input.customerId ? { customerId: input.customerId } : {}),
        },
      });

      if (!intent.client_secret) {
        // Should never happen; treat as a server-side fault rather than leaking internals.
        throw ApiError.internal('Stripe did not return a client secret');
      }

      this.logger.info(
        { intentId: intent.id, amount: input.amount, currency: input.currency },
        'payment intent created',
      );

      return { id: intent.id, clientSecret: intent.client_secret, status: intent.status };
    } catch (err) {
      if (err instanceof ApiError) throw err;
      if (err instanceof Stripe.errors.StripeError) {
        this.logger.error({ stripeError: err.message, type: err.type }, 'stripe error');
        throw new ApiError(502, 'stripe_error', 'Payment provider returned an error');
      }
      throw err;
    }
  }
}

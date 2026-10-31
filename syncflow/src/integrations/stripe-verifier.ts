import Stripe from 'stripe';
import { ApiError } from '../utils/api-error.js';
import type { StripeWebhookVerifier, VerifiedStripeEvent } from './types.js';

/**
 * Signature verification via the official Stripe SDK. `constructEvent` throws
 * on a bad signature or a timestamp outside the tolerance window (replay
 * protection). A throwaway API key is fine here: webhook verification is a
 * purely local HMAC computation, no API calls are made.
 */
export class SdkStripeWebhookVerifier implements StripeWebhookVerifier {
  private readonly stripe: Stripe;

  constructor(private readonly webhookSecret: string) {
    this.stripe = new Stripe('sk_test_unused', { typescript: true });
  }

  verify(rawBody: Buffer, signatureHeader: string | undefined): VerifiedStripeEvent {
    if (!signatureHeader) {
      throw ApiError.unauthorized('missing_signature', 'stripe-signature header is required');
    }
    try {
      const event = this.stripe.webhooks.constructEvent(
        rawBody,
        signatureHeader,
        this.webhookSecret,
      );
      return {
        id: event.id,
        type: event.type,
        data: event.data.object as unknown as Record<string, unknown>,
      };
    } catch {
      throw ApiError.unauthorized('invalid_signature', 'Stripe webhook signature verification failed');
    }
  }
}

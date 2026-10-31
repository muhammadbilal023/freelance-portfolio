import express, { Router } from 'express';
import type { Logger } from 'pino';
import type { AppConfig } from '../config.js';
import type { JobsRepository, WebhookEventsRepository } from '../db/repositories.js';
import {
  SHOPIFY_ORDER_JOB,
  normalizeShopifyOrder,
} from '../flows/shopify-order.flow.js';
import {
  STRIPE_PAYMENT_JOB,
  parseStripePaymentEvent,
} from '../flows/stripe-payment.flow.js';
import type { ShopifyWebhookVerifier, StripeWebhookVerifier } from '../integrations/types.js';
import { ApiError } from '../utils/api-error.js';

export interface WebhooksDeps {
  config: AppConfig;
  logger: Logger;
  events: WebhookEventsRepository;
  jobs: JobsRepository;
  stripeVerifier: StripeWebhookVerifier | null;
  shopifyVerifier: ShopifyWebhookVerifier | null;
}

/**
 * Inbound provider webhooks. Bodies are consumed RAW (express.raw) because
 * both Stripe and Shopify sign the exact byte sequence they sent — any
 * parse/re-serialise step would break signature verification.
 */
export function createWebhooksRouter(deps: WebhooksDeps): Router {
  const router = Router();

  // Flow 1: Stripe payment succeeded -> Sheets + HubSpot
  router.post('/stripe', express.raw({ type: '*/*' }), (req, res) => {
    if (!deps.stripeVerifier) throw ApiError.notConfigured('Stripe webhooks');

    const event = deps.stripeVerifier.verify(
      req.body as Buffer,
      req.header('stripe-signature'),
    );
    const payload = parseStripePaymentEvent(event);
    if (!payload) {
      deps.logger.debug({ eventType: event.type }, 'ignoring unhandled Stripe event');
      res.status(200).json({ accepted: false, reason: 'event_type_not_handled' });
      return;
    }

    const isNew = deps.events.record({
      provider: 'stripe',
      externalEventId: event.id,
      eventType: event.type,
      payload,
    });
    if (!isNew) {
      res.status(200).json({ accepted: false, reason: 'duplicate' });
      return;
    }

    const job = deps.jobs.enqueue(STRIPE_PAYMENT_JOB, payload, {
      maxAttempts: deps.config.JOB_MAX_ATTEMPTS,
    });
    deps.logger.info({ eventId: event.id, jobId: job.id }, 'stripe payment queued');
    res.status(202).json({ accepted: true, jobId: job.id });
  });

  // Flow 2: Shopify new order -> Airtable + Slack
  router.post('/shopify', express.raw({ type: '*/*' }), (req, res) => {
    if (!deps.shopifyVerifier) throw ApiError.notConfigured('Shopify webhooks');

    const verified = deps.shopifyVerifier.verify(
      req.body as Buffer,
      req.header('x-shopify-hmac-sha256'),
    );
    if (!verified) {
      throw ApiError.unauthorized('invalid_signature', 'Shopify HMAC verification failed');
    }

    const topic = req.header('x-shopify-topic') ?? '';
    if (topic !== 'orders/create') {
      res.status(200).json({ accepted: false, reason: 'topic_not_handled' });
      return;
    }

    let body: unknown;
    try {
      body = JSON.parse((req.body as Buffer).toString('utf8'));
    } catch {
      throw ApiError.badRequest('invalid_json', 'Webhook body is not valid JSON');
    }

    const order = normalizeShopifyOrder(body);
    if (!order) {
      throw new ApiError(422, 'invalid_payload', 'Shopify order could not be normalised');
    }

    // Prefer Shopify's own delivery id; fall back to the order id.
    const externalEventId = req.header('x-shopify-webhook-id') ?? `order-${order.orderId}`;
    const isNew = deps.events.record({
      provider: 'shopify',
      externalEventId,
      eventType: topic,
      payload: order,
    });
    if (!isNew) {
      res.status(200).json({ accepted: false, reason: 'duplicate' });
      return;
    }

    const job = deps.jobs.enqueue(SHOPIFY_ORDER_JOB, order, {
      maxAttempts: deps.config.JOB_MAX_ATTEMPTS,
    });
    deps.logger.info({ orderId: order.orderId, jobId: job.id }, 'shopify order queued');
    res.status(202).json({ accepted: true, jobId: job.id });
  });

  return router;
}

import { z } from 'zod';
import type { AppConfig } from '../config.js';
import type { SyncLedgerRepository } from '../db/repositories.js';
import type { Integrations, VerifiedStripeEvent } from '../integrations/types.js';
import type { JobHandler } from '../queue/job-runner.js';
import { runIdempotentStep } from './steps.js';

export const STRIPE_PAYMENT_JOB = 'stripe.payment.sync';

/** Only this event type drives Flow 1; everything else is acknowledged and ignored. */
export const SUPPORTED_STRIPE_EVENT = 'payment_intent.succeeded';

export interface StripePaymentJobPayload {
  paymentIntentId: string;
  amountCents: number;
  currency: string;
  customerEmail: string;
  customerName: string;
  paidAt: string;
}

const payloadSchema = z.object({
  paymentIntentId: z.string().min(1),
  amountCents: z.number().int().nonnegative(),
  currency: z.string().length(3),
  customerEmail: z.string(),
  customerName: z.string(),
  paidAt: z.string(),
});

/**
 * Extracts the flow payload from a verified Stripe event, or `null` when the
 * event is not the supported type or lacks the fields the flow needs.
 */
export function parseStripePaymentEvent(
  event: VerifiedStripeEvent,
): StripePaymentJobPayload | null {
  if (event.type !== SUPPORTED_STRIPE_EVENT) return null;

  const intent = event.data as {
    id?: string;
    amount?: number;
    currency?: string;
    receipt_email?: string | null;
    charges?: { data?: { billing_details?: { name?: string | null; email?: string | null } }[] };
  };
  const billing = intent.charges?.data?.[0]?.billing_details;
  const email = billing?.email ?? intent.receipt_email ?? '';

  const parsed = payloadSchema.safeParse({
    paymentIntentId: intent.id ?? '',
    amountCents: intent.amount ?? -1,
    currency: (intent.currency ?? '').toUpperCase(),
    customerEmail: email,
    customerName: billing?.name ?? '',
    paidAt: new Date().toISOString(),
  });
  return parsed.success ? parsed.data : null;
}

/**
 * Flow 1: payment succeeded -> append a row to Google Sheets -> upsert the
 * contact + deal in HubSpot.
 *
 * Each step is guarded by the sync ledger keyed on the payment intent id, so
 * a job retried after a partial failure never appends the row twice.
 */
export function createStripePaymentHandler(
  config: AppConfig,
  integrations: Integrations,
  ledger: SyncLedgerRepository,
): JobHandler {
  return async (payload: unknown) => {
    const parsed = payloadSchema.parse(payload);

    await runIdempotentStep(
      ledger,
      `${STRIPE_PAYMENT_JOB}:sheets`,
      parsed.paymentIntentId,
      () =>
        integrations.sheets.appendRow(config.PAYMENTS_SHEET_ID, config.PAYMENTS_SHEET_NAME, [
          parsed.paidAt,
          parsed.paymentIntentId,
          parsed.amountCents / 100,
          parsed.currency,
          parsed.customerEmail,
          parsed.customerName,
        ]),
    );

    if (!parsed.customerEmail) return;
    const [firstName, ...rest] = parsed.customerName.split(' ');
    await runIdempotentStep(
      ledger,
      `${STRIPE_PAYMENT_JOB}:hubspot`,
      parsed.paymentIntentId,
      () =>
        integrations.hubspot.upsertContactWithDeal({
          email: parsed.customerEmail,
          firstName,
          lastName: rest.join(' ') || undefined,
          dealName: `Payment ${parsed.paymentIntentId}`,
          amount: (parsed.amountCents / 100).toFixed(2),
          stage: 'closedwon',
        }),
    );
  };
}

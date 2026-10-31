import { z } from 'zod';
import type { AppConfig } from '../config.js';
import type { SyncLedgerRepository } from '../db/repositories.js';
import type { Integrations } from '../integrations/types.js';
import type { JobHandler } from '../queue/job-runner.js';
import { runIdempotentStep } from './steps.js';

export const SHOPIFY_ORDER_JOB = 'shopify.order.sync';

/** Order shape after normalisation — the only form downstream steps see. */
export const normalizedOrderSchema = z.object({
  orderId: z.string().min(1),
  orderNumber: z.string(),
  customerName: z.string(),
  customerEmail: z.string(),
  totalPrice: z.string(),
  currency: z.string(),
  financialStatus: z.string(),
  itemCount: z.number().int().nonnegative(),
  createdAt: z.string(),
});

export type NormalizedOrder = z.infer<typeof normalizedOrderSchema>;

/**
 * Maps a raw Shopify `orders/create` webhook body onto [NormalizedOrder].
 * Returns `null` when the payload is unusable so the route can reject it
 * with a 422 instead of queueing a job that can only ever fail.
 */
export function normalizeShopifyOrder(raw: unknown): NormalizedOrder | null {
  const order = raw as {
    id?: number;
    order_number?: number;
    customer?: { first_name?: string; last_name?: string; email?: string };
    email?: string;
    total_price?: string;
    currency?: string;
    financial_status?: string;
    line_items?: unknown[];
    created_at?: string;
  };

  const parsed = normalizedOrderSchema.safeParse({
    orderId: order.id !== undefined ? String(order.id) : '',
    orderNumber: order.order_number !== undefined ? String(order.order_number) : '',
    customerName:
      [order.customer?.first_name, order.customer?.last_name].filter(Boolean).join(' ') ?? '',
    customerEmail: order.customer?.email ?? order.email ?? '',
    totalPrice: order.total_price ?? '',
    currency: order.currency ?? '',
    financialStatus: order.financial_status ?? 'pending',
    itemCount: Array.isArray(order.line_items) ? order.line_items.length : 0,
    createdAt: order.created_at ?? new Date().toISOString(),
  });
  return parsed.success ? parsed.data : null;
}

/**
 * Flow 2: new Shopify order -> create an Airtable record -> notify Slack.
 * Ledger claims per step keep retries from duplicating the record or the
 * notification.
 */
export function createShopifyOrderHandler(
  config: AppConfig,
  integrations: Integrations,
  ledger: SyncLedgerRepository,
): JobHandler {
  return async (payload: unknown) => {
    const order = normalizedOrderSchema.parse(payload);

    await runIdempotentStep(ledger, `${SHOPIFY_ORDER_JOB}:airtable`, order.orderId, () =>
      integrations.airtable.createRecord(
        config.AIRTABLE_BASE_ID,
        config.AIRTABLE_ORDERS_TABLE,
        {
          OrderId: order.orderId,
          OrderNumber: order.orderNumber,
          Customer: order.customerName,
          Email: order.customerEmail,
          Total: Number(order.totalPrice),
          Currency: order.currency,
          Status: order.financialStatus,
          Items: order.itemCount,
          OrderedAt: order.createdAt,
        },
      ).then(() => undefined),
    );

    await runIdempotentStep(ledger, `${SHOPIFY_ORDER_JOB}:slack`, order.orderId, () =>
      integrations.slack.postMessage(
        `:shopping_cart: New order #${order.orderNumber} from ${order.customerName || 'a customer'} — ` +
          `${order.currency} ${order.totalPrice} (${order.itemCount} item(s), ${order.financialStatus})`,
      ),
    );
  };
}

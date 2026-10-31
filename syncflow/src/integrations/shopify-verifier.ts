import crypto from 'node:crypto';
import type { ShopifyWebhookVerifier } from './types.js';

/**
 * Shopify signs the raw request body with HMAC-SHA256 using the app's client
 * secret and sends the base64 digest in `X-Shopify-Hmac-Sha256`.
 * Comparison uses timingSafeEqual to avoid leaking the digest byte-by-byte.
 */
export class HmacShopifyWebhookVerifier implements ShopifyWebhookVerifier {
  constructor(private readonly secret: string) {}

  verify(rawBody: Buffer, hmacHeader: string | undefined): boolean {
    if (!hmacHeader) return false;
    const digest = crypto.createHmac('sha256', this.secret).update(rawBody).digest('base64');

    const expected = Buffer.from(digest, 'utf8');
    const received = Buffer.from(hmacHeader, 'utf8');
    if (expected.length !== received.length) return false;
    return crypto.timingSafeEqual(expected, received);
  }
}

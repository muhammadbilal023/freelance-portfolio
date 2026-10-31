import { describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.js';

describe('loadConfig', () => {
  it('applies defaults and parses comma-separated CORS origins', () => {
    const config = loadConfig({
      STRIPE_SECRET_KEY: 'sk_test_abc',
      CORS_ORIGINS: 'http://a.com, http://b.com',
    });

    expect(config.PORT).toBe(8080);
    expect(config.MAX_AMOUNT_CENTS).toBe(100_000);
    expect(config.CORS_ORIGINS).toEqual(['http://a.com', 'http://b.com']);
  });

  it('fails fast when the Stripe key is missing', () => {
    expect(() => loadConfig({})).toThrow(/STRIPE_SECRET_KEY/);
  });

  it('refuses live-mode Stripe keys', () => {
    expect(() => loadConfig({ STRIPE_SECRET_KEY: 'sk_live_abc' })).toThrow(/TEST-mode/);
  });
});

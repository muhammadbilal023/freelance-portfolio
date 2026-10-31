import pino, { type Logger } from 'pino';
import type { AppConfig } from './config.js';

export function createLogger(config: AppConfig): Logger {
  return pino({
    level: config.LOG_LEVEL,
    redact: {
      // Never leak credentials or raw webhook signature headers into logs.
      paths: [
        'req.headers.authorization',
        'req.headers["stripe-signature"]',
        'req.headers["x-shopify-hmac-sha256"]',
        '*.HUBSPOT_ACCESS_TOKEN',
        '*.AIRTABLE_API_KEY',
        '*.SLACK_WEBHOOK_URL',
      ],
      censor: '[REDACTED]',
    },
    ...(config.LOG_PRETTY
      ? {
          transport: {
            target: 'pino-pretty',
            options: { colorize: true, translateTime: 'SYS:HH:MM:ss' },
          },
        }
      : {}),
  });
}

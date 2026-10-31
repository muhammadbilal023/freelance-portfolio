import pino, { type Logger } from 'pino';
import type { AppConfig } from './config.js';

export function createLogger(config: AppConfig): Logger {
  return pino({
    level: config.LOG_LEVEL,
    redact: {
      // Never leak secrets or full card-related payloads into logs.
      paths: ['req.headers.authorization', 'req.body.payment_method', '*.STRIPE_SECRET_KEY'],
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

import express, { type Express } from 'express';
import helmet from 'helmet';
import cors from 'cors';
import { pinoHttp } from 'pino-http';
import type { Logger } from 'pino';
import type { AppConfig } from './config.js';
import { createHealthRouter } from './routes/health.routes.js';
import { createPaymentsRouter } from './routes/payments.routes.js';
import { createErrorHandler, notFoundHandler } from './middleware/error-handler.js';
import type { PaymentGateway } from './services/stripe.service.js';

export interface AppDependencies {
  config: AppConfig;
  logger: Logger;
  gateway: PaymentGateway;
}

/**
 * App factory — kept separate from the HTTP bootstrap (index.ts) so tests
 * can create an isolated app instance with injected fakes.
 */
export function createApp({ config, logger, gateway }: AppDependencies): Express {
  const app = express();

  app.disable('x-powered-by');
  app.use(helmet());
  app.use(
    cors({
      origin: config.CORS_ORIGINS,
      methods: ['GET', 'POST'],
    }),
  );
  app.use(express.json({ limit: '16kb' }));
  app.use(
    pinoHttp({
      logger,
      // One concise line per request; full error objects are logged by the error handler.
      customLogLevel: (_req, res, err) =>
        err || res.statusCode >= 500 ? 'error' : res.statusCode >= 400 ? 'warn' : 'info',
    }),
  );

  app.use(createHealthRouter());
  app.use('/api/payments', createPaymentsRouter(gateway, config.MAX_AMOUNT_CENTS));

  app.use(notFoundHandler);
  app.use(createErrorHandler(logger));

  return app;
}

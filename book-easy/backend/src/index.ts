import { loadConfig } from './config.js';
import { createLogger } from './logger.js';
import { createApp } from './app.js';
import { StripePaymentGateway } from './services/stripe.service.js';

function main(): void {
  const config = loadConfig();
  const logger = createLogger(config);
  const gateway = new StripePaymentGateway(config.STRIPE_SECRET_KEY, config.MAX_AMOUNT_CENTS, logger);
  const app = createApp({ config, logger, gateway });

  const server = app.listen(config.PORT, () => {
    logger.info({ port: config.PORT }, 'BookEasy payments API started');
  });

  // Graceful shutdown: stop accepting connections, then exit.
  const shutdown = (signal: string) => {
    logger.info({ signal }, 'shutting down');
    server.close(() => process.exit(0));
    // Force-exit if connections refuse to drain.
    setTimeout(() => process.exit(1), 10_000).unref();
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

main();

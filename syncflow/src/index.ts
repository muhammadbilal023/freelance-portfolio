import 'dotenv/config';
import { buildServices } from './app.js';
import { loadConfig } from './config.js';
import { openDatabase } from './db/database.js';
import { createLogger } from './logger.js';

function main(): void {
  const config = loadConfig();
  const logger = createLogger(config);
  const db = openDatabase(config.DATABASE_PATH);

  const services = buildServices({ config, logger, db });
  services.runner.start();
  services.pullScheduler.start();

  const server = services.app.listen(config.PORT, () => {
    logger.info({ port: config.PORT }, 'SyncFlow listening');
    warnAboutMissingCredentials();
  });

  function warnAboutMissingCredentials(): void {
    const missing: string[] = [];
    if (!config.STRIPE_WEBHOOK_SECRET) missing.push('STRIPE_WEBHOOK_SECRET');
    if (!config.SHOPIFY_HMAC_SECRET) missing.push('SHOPIFY_HMAC_SECRET');
    if (!config.GOOGLE_SERVICE_ACCOUNT_KEY_PATH) missing.push('GOOGLE_SERVICE_ACCOUNT_KEY_PATH');
    if (!config.HUBSPOT_ACCESS_TOKEN) missing.push('HUBSPOT_ACCESS_TOKEN');
    if (!config.AIRTABLE_API_KEY) missing.push('AIRTABLE_API_KEY');
    if (!config.SLACK_WEBHOOK_URL) missing.push('SLACK_WEBHOOK_URL');
    if (missing.length > 0) {
      logger.warn(
        { missing },
        'integrations not configured — affected flows will dead-letter with a ConfigError',
      );
    }
  }

  // Graceful shutdown: stop accepting work, finish in-flight requests, close.
  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.on(signal, () => {
      logger.info({ signal }, 'shutting down');
      services.runner.stop();
      services.pullScheduler.stop();
      server.close(() => {
        db.close();
        process.exit(0);
      });
      // Force-exit if connections refuse to drain.
      setTimeout(() => process.exit(1), 10_000).unref();
    });
  }
}

try {
  main();
} catch (err) {
  // Config/DB failures happen before the logger may exist — stderr is fine here.
  process.stderr.write(`SyncFlow failed to start: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
}

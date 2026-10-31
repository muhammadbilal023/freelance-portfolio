import type { AppConfig } from '../config.js';
import { GoogleAccessTokenProvider } from './google-auth.js';
import { HttpHubspotClient } from './hubspot-client.js';
import { HttpAirtableClient, HttpSheetsClient, HttpSlackClient } from './http-clients.js';
import type { Integrations } from './types.js';

const SHEETS_SCOPE = 'https://www.googleapis.com/auth/spreadsheets';

/**
 * Wires the real HTTP-backed clients. Missing credentials are NOT an error
 * here — each client throws a descriptive ConfigError when actually used, so
 * unconfigured flows fail into the dead-letter table with a clear message.
 */
export function createIntegrations(config: AppConfig): Integrations {
  const tokens = config.GOOGLE_SERVICE_ACCOUNT_KEY_PATH
    ? GoogleAccessTokenProvider.fromKeyFile(config.GOOGLE_SERVICE_ACCOUNT_KEY_PATH, SHEETS_SCOPE)
    : null;

  return {
    sheets: new HttpSheetsClient(tokens),
    hubspot: new HttpHubspotClient(config.HUBSPOT_ACCESS_TOKEN),
    airtable: new HttpAirtableClient(config.AIRTABLE_API_KEY),
    slack: new HttpSlackClient(config.SLACK_WEBHOOK_URL),
  };
}

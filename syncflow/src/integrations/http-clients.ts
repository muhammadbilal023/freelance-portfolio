import { ConfigError, RateLimitError } from '../utils/api-error.js';
import type { GoogleAccessTokenProvider } from './google-auth.js';
import type { AirtableClient, AirtableRecord, SheetsClient, SlackClient } from './types.js';

const REQUEST_TIMEOUT_MS = 15_000;

async function readError(response: Response, provider: string): Promise<Error> {
  const body = await response.text().catch(() => '');
  if (response.status === 429) {
    const retryAfterSec = Number(response.headers.get('retry-after') ?? '30');
    return new RateLimitError(
      Math.max(retryAfterSec, 1) * 1000,
      `${provider} rate limit exceeded (HTTP 429)`,
    );
  }
  return new Error(`${provider} API error HTTP ${response.status}: ${body.slice(0, 300)}`);
}

// ---- Google Sheets -------------------------------------------------------------

export class HttpSheetsClient implements SheetsClient {
  constructor(private readonly tokens: GoogleAccessTokenProvider | null) {}

  async appendRow(
    spreadsheetId: string,
    sheetName: string,
    row: (string | number)[],
  ): Promise<void> {
    if (!this.tokens) throw new ConfigError('Google Sheets');
    if (!spreadsheetId) throw new ConfigError('Target spreadsheet id (SHEET_ID)');

    const token = await this.tokens.getToken();
    const url =
      `https://sheets.googleapis.com/v4/spreadsheets/${encodeURIComponent(spreadsheetId)}` +
      `/values/${encodeURIComponent(sheetName)}!A1:append?valueInputOption=USER_ENTERED`;

    const response = await fetch(url, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ values: [row] }),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    if (!response.ok) throw await readError(response, 'Google Sheets');
  }
}

// ---- Airtable ---------------------------------------------------------------------

export class HttpAirtableClient implements AirtableClient {
  constructor(private readonly apiKey: string) {}

  private ensureConfigured(): void {
    if (!this.apiKey) throw new ConfigError('Airtable');
  }

  async listRecords(baseId: string, table: string): Promise<AirtableRecord[]> {
    this.ensureConfigured();
    const records: AirtableRecord[] = [];
    let offset: string | undefined;

    // Page through the table (Airtable returns at most 100 records per page).
    do {
      const params = new URLSearchParams({ pageSize: '100' });
      if (offset) params.set('offset', offset);
      const response = await fetch(
        `https://api.airtable.com/v0/${encodeURIComponent(baseId)}/${encodeURIComponent(table)}?${params}`,
        {
          headers: { authorization: `Bearer ${this.apiKey}` },
          signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        },
      );
      if (!response.ok) throw await readError(response, 'Airtable');
      const body = (await response.json()) as { records: AirtableRecord[]; offset?: string };
      records.push(...body.records);
      offset = body.offset;
    } while (offset);

    return records;
  }

  async createRecord(
    baseId: string,
    table: string,
    fields: Record<string, unknown>,
  ): Promise<string> {
    this.ensureConfigured();
    const response = await fetch(
      `https://api.airtable.com/v0/${encodeURIComponent(baseId)}/${encodeURIComponent(table)}`,
      {
        method: 'POST',
        headers: { authorization: `Bearer ${this.apiKey}`, 'content-type': 'application/json' },
        body: JSON.stringify({ fields }),
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      },
    );
    if (!response.ok) throw await readError(response, 'Airtable');
    const body = (await response.json()) as { id: string };
    return body.id;
  }
}

// ---- Slack ------------------------------------------------------------------------

export class HttpSlackClient implements SlackClient {
  constructor(private readonly webhookUrl: string) {}

  async postMessage(text: string): Promise<void> {
    if (!this.webhookUrl) throw new ConfigError('Slack');
    const response = await fetch(this.webhookUrl, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ text }),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    if (!response.ok) throw await readError(response, 'Slack');
  }
}

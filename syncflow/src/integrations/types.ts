/**
 * Integration contracts. Everything the flows touch externally sits behind
 * one of these interfaces so tests can swap in in-memory fakes and the
 * business logic never knows which SaaS it is talking to.
 */

// ---- Inbound webhook verification --------------------------------------------

export interface VerifiedStripeEvent {
  id: string;
  type: string;
  data: Record<string, unknown>;
}

export interface StripeWebhookVerifier {
  /** Throws when the signature is missing, malformed or does not match. */
  verify(rawBody: Buffer, signatureHeader: string | undefined): VerifiedStripeEvent;
}

export interface ShopifyWebhookVerifier {
  /** Constant-time comparison of the HMAC against the raw request body. */
  verify(rawBody: Buffer, hmacHeader: string | undefined): boolean;
}

// ---- Outbound clients ----------------------------------------------------------

export interface SheetsClient {
  appendRow(spreadsheetId: string, sheetName: string, row: (string | number)[]): Promise<void>;
}

export interface HubspotDealInput {
  email: string;
  firstName?: string;
  lastName?: string;
  dealName: string;
  amount: string;
  stage: string;
}

export interface HubspotClient {
  /** Creates the contact if missing (keyed on email), then attaches a deal. */
  upsertContactWithDeal(input: HubspotDealInput): Promise<void>;
}

export interface AirtableRecord {
  id: string;
  fields: Record<string, unknown>;
  createdTime: string;
}

export interface AirtableClient {
  listRecords(baseId: string, table: string): Promise<AirtableRecord[]>;
  createRecord(
    baseId: string,
    table: string,
    fields: Record<string, unknown>,
  ): Promise<string>;
}

export interface SlackClient {
  postMessage(text: string): Promise<void>;
}

/** Everything a flow may need; passed as one bundle for convenience. */
export interface Integrations {
  sheets: SheetsClient;
  hubspot: HubspotClient;
  airtable: AirtableClient;
  slack: SlackClient;
}

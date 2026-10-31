import { ConfigError, RateLimitError } from '../utils/api-error.js';
import type { HubspotClient, HubspotDealInput } from './types.js';

const REQUEST_TIMEOUT_MS = 15_000;
const API_BASE = 'https://api.hubapi.com';

/**
 * HubSpot CRM client using the private-app access token.
 * Contact upsert is keyed on email (HubSpot's natural identity for contacts);
 * the deal is then associated with the contact.
 */
export class HttpHubspotClient implements HubspotClient {
  constructor(private readonly accessToken: string) {}

  async upsertContactWithDeal(input: HubspotDealInput): Promise<void> {
    if (!this.accessToken) throw new ConfigError('HubSpot');

    const contactId = await this.upsertContact(input);
    await this.createDeal(input, contactId);
  }

  private async upsertContact(input: HubspotDealInput): Promise<string> {
    const response = await this.request('/crm/v3/objects/contacts?idProperty=email', 'PUT', {
      properties: {
        email: input.email,
        ...(input.firstName ? { firstname: input.firstName } : {}),
        ...(input.lastName ? { lastname: input.lastName } : {}),
      },
    });
    return response.id;
  }

  private async createDeal(input: HubspotDealInput, contactId: string): Promise<string> {
    const response = await this.request('/crm/v3/objects/deals', 'POST', {
      properties: {
        dealname: input.dealName,
        amount: input.amount,
        dealstage: input.stage,
        pipeline: 'default',
      },
      associations: [
        {
          to: { id: contactId },
          types: [{ associationCategory: 'HUBSPOT_DEFINED', associationTypeId: 3 }],
        },
      ],
    });
    return response.id;
  }

  private async request(
    path: string,
    method: 'GET' | 'POST' | 'PUT',
    body: unknown,
  ): Promise<{ id: string }> {
    const response = await fetch(`${API_BASE}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${this.accessToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });

    if (!response.ok) {
      const text = await response.text().catch(() => '');
      if (response.status === 429) {
        throw new RateLimitError(30_000, 'HubSpot rate limit exceeded (HTTP 429)');
      }
      throw new Error(`HubSpot API error HTTP ${response.status}: ${text.slice(0, 300)}`);
    }
    return (await response.json()) as { id: string };
  }
}

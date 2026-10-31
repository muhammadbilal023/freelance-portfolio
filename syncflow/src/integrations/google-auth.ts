import crypto from 'node:crypto';
import fs from 'node:fs';

interface ServiceAccountKey {
  client_email: string;
  private_key: string;
  token_uri: string;
}

/**
 * Minimal Google service-account OAuth2 (JWT bearer, RS256) — the same flow
 * the official google-auth-library performs, without the dependency.
 * Access tokens are cached until shortly before expiry.
 */
export class GoogleAccessTokenProvider {
  private cached: { token: string; expiresAtMs: number } | null = null;

  constructor(
    private readonly key: ServiceAccountKey,
    private readonly scope: string,
  ) {}

  static fromKeyFile(path: string, scope: string): GoogleAccessTokenProvider {
    const key = JSON.parse(fs.readFileSync(path, 'utf8')) as ServiceAccountKey;
    return new GoogleAccessTokenProvider(key, scope);
  }

  async getToken(): Promise<string> {
    if (this.cached && Date.now() < this.cached.expiresAtMs - 60_000) {
      return this.cached.token;
    }
    const assertion = this.buildSignedJwt();
    const response = await fetch(this.key.token_uri, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion,
      }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) {
      throw new Error(`Google token exchange failed with HTTP ${response.status}`);
    }
    const body = (await response.json()) as { access_token: string; expires_in: number };
    this.cached = {
      token: body.access_token,
      expiresAtMs: Date.now() + body.expires_in * 1000,
    };
    return this.cached.token;
  }

  private buildSignedJwt(): string {
    const nowSec = Math.floor(Date.now() / 1000);
    const encode = (obj: object) =>
      Buffer.from(JSON.stringify(obj)).toString('base64url');

    const header = encode({ alg: 'RS256', typ: 'JWT' });
    const claims = encode({
      iss: this.key.client_email,
      scope: this.scope,
      aud: this.key.token_uri,
      iat: nowSec,
      exp: nowSec + 3600,
    });
    const signature = crypto
      .createSign('RSA-SHA256')
      .update(`${header}.${claims}`)
      .sign(this.key.private_key)
      .toString('base64url');
    return `${header}.${claims}.${signature}`;
  }
}

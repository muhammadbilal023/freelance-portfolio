import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { buildTestApp } from './helpers/test-app.js';

interface HealthBody {
  status: string;
  uptime: number;
}

interface ErrorBody {
  error: { code: string; message: string };
}

describe('GET /health', () => {
  it('returns ok status', async () => {
    const { app } = buildTestApp();
    const res = await request(app).get('/health').expect(200);
    const body = res.body as HealthBody;
    expect(body.status).toBe('ok');
    expect(typeof body.uptime).toBe('number');
  });

  it('returns 404 with a stable error envelope for unknown routes', async () => {
    const { app } = buildTestApp();
    const res = await request(app).get('/nope').expect(404);
    expect((res.body as ErrorBody).error).toMatchObject({ code: 'not_found' });
  });
});

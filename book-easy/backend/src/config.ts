import 'dotenv/config';
import { z } from 'zod';

/**
 * Environment schema — validated once at startup so the process fails fast
 * with a readable message instead of crashing later on undefined values.
 */
const envSchema = z.object({
  PORT: z.coerce.number().int().positive().default(8080),
  CORS_ORIGINS: z
    .string()
    .default('http://localhost:3000')
    .transform((raw) => raw.split(',').map((o) => o.trim()).filter(Boolean)),
  STRIPE_SECRET_KEY: z
    .string()
    .min(1, 'STRIPE_SECRET_KEY is required')
    // Fail fast if someone accidentally pastes a live key into this sample repo.
    .refine((key) => key.startsWith('sk_test_'), {
      message: 'Only Stripe TEST-mode keys (sk_test_...) are allowed in this project',
    }),
  MAX_AMOUNT_CENTS: z.coerce.number().int().positive().default(100_000),
  LOG_LEVEL: z
    .enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace'])
    .default('info'),
  LOG_PRETTY: z
    .string()
    .default('false')
    .transform((v) => v === 'true'),
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
});

export type AppConfig = z.infer<typeof envSchema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const result = envSchema.safeParse(env);
  if (!result.success) {
    const details = result.error.issues
      .map((i) => `  - ${i.path.join('.')}: ${i.message}`)
      .join('\n');
    throw new Error(`Invalid environment configuration:\n${details}`);
  }
  return result.data;
}

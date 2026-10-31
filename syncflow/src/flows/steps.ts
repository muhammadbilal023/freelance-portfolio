import type { SyncLedgerRepository } from '../db/repositories.js';

/**
 * Runs one side-effecting flow step exactly once per (source, key).
 *
 * The ledger claim is taken BEFORE the step so concurrent retries cannot
 * both execute it, and released again if the step throws — otherwise a
 * partial failure would permanently skip the broken step on retry.
 */
export async function runIdempotentStep(
  ledger: SyncLedgerRepository,
  source: string,
  key: string,
  step: () => Promise<void>,
): Promise<void> {
  if (!ledger.tryClaim(source, key)) return;
  try {
    await step();
  } catch (err) {
    ledger.release(source, key);
    throw err;
  }
}

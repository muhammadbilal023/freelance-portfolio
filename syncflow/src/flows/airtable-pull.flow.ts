import type { AppConfig } from '../config.js';
import type { SyncLedgerRepository } from '../db/repositories.js';
import type { Integrations } from '../integrations/types.js';
import type { JobHandler } from '../queue/job-runner.js';
import { runIdempotentStep } from './steps.js';

export const AIRTABLE_PULL_JOB = 'airtable.pull.sync';
const LEDGER_SOURCE = 'airtable-pull';

/**
 * Flow 3 (scheduled): pull every record from the Airtable inbox table and
 * append the ones never seen before to the mirror Google Sheet.
 *
 * Duplicate protection: the sync ledger's PRIMARY KEY(source, record_id)
 * makes `tryClaim` succeed exactly once per Airtable record, no matter how
 * often the schedule fires or how many times a job is retried.
 */
export function createAirtablePullHandler(
  config: AppConfig,
  integrations: Integrations,
  ledger: SyncLedgerRepository,
): JobHandler {
  return async () => {
    const records = await integrations.airtable.listRecords(
      config.AIRTABLE_BASE_ID,
      config.AIRTABLE_PULL_TABLE,
    );

    for (const record of records) {
      await runIdempotentStep(ledger, LEDGER_SOURCE, record.id, () =>
        integrations.sheets.appendRow(
          config.AIRTABLE_MIRROR_SHEET_ID,
          config.AIRTABLE_MIRROR_SHEET_NAME,
          [record.id, record.createdTime, JSON.stringify(record.fields)],
        ),
      );
    }
  };
}

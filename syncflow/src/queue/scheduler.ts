import type { Logger } from 'pino';

/**
 * Runs an async task on a fixed interval. Errors are logged, never thrown —
 * a failing tick must not kill the schedule. `runOnce` is exposed for tests
 * and for an immediate first execution at startup.
 */
export class Scheduler {
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly name: string,
    private readonly intervalMs: number,
    private readonly task: () => void | Promise<void>,
    private readonly logger: Logger,
  ) {}

  start(options: { runImmediately?: boolean } = {}): void {
    if (this.timer) return;
    if (options.runImmediately) {
      this.runOnce().catch(() => {});
    }
    this.timer = setInterval(() => {
      this.runOnce().catch(() => {});
    }, this.intervalMs);
    this.timer.unref?.();
    this.logger.info({ scheduler: this.name, intervalMs: this.intervalMs }, 'scheduler started');
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  async runOnce(): Promise<void> {
    try {
      await Promise.resolve(this.task());
    } catch (err) {
      this.logger.error({ err, scheduler: this.name }, 'scheduled task failed');
    }
  }
}

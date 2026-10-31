export interface BackoffOptions {
  baseMs: number;
  maxMs: number;
}

/**
 * Exponential backoff with "equal jitter": half deterministic exponential
 * delay, half random. Jitter prevents a thundering herd of retries after a
 * provider outage. `random` is injectable to keep this pure and testable.
 *
 * attempt is 1-based: attempt 1 -> ~baseMs, attempt 2 -> ~2*baseMs, ...
 */
export function computeBackoffMs(
  attempt: number,
  options: BackoffOptions,
  random: () => number = Math.random,
): number {
  if (attempt < 1) throw new RangeError('attempt must be >= 1');
  const exponential = Math.min(options.baseMs * 2 ** (attempt - 1), options.maxMs);
  const half = exponential / 2;
  return Math.round(half + half * random());
}

/** Outcome of a rate limit check. */
export interface RateLimitDecision {
  readonly allowed: boolean;
  /** Seconds until one more request would be allowed; 0 when allowed. */
  readonly retryAfterSeconds: number;
}

/** Options for [TokenBucketLimiter]. */
export interface TokenBucketOptions {
  readonly burst: number;
  readonly refillPerHour: number;
  /** Upper bound on tracked keys, so memory stays bounded. */
  readonly maxEntries?: number;
  readonly now?: () => number;
}

interface Bucket {
  tokens: number;
  updatedAt: number;
}

/**
 * In-memory token bucket per key. Each function instance keeps its own map, so
 * the effective limit is this one times the instance count; `maxInstances`
 * bounds that.
 */
export class TokenBucketLimiter {
  private readonly burst: number;
  private readonly refillPerMs: number;
  private readonly maxEntries: number;
  private readonly now: () => number;
  private readonly buckets = new Map<string, Bucket>();

  constructor(options: TokenBucketOptions) {
    this.burst = options.burst;
    this.refillPerMs = options.refillPerHour / 3_600_000;
    this.maxEntries = options.maxEntries ?? 10_000;
    this.now = options.now ?? Date.now;
  }

  /** Spends one token for [key] when one is available. */
  take(key: string): RateLimitDecision {
    const now = this.now();
    const existing = this.buckets.get(key);
    const bucket: Bucket = existing ?? { tokens: this.burst, updatedAt: now };
    const elapsed = Math.max(0, now - bucket.updatedAt);
    bucket.tokens = Math.min(
      this.burst,
      bucket.tokens + elapsed * this.refillPerMs,
    );
    bucket.updatedAt = now;
    // Re-insert so iteration order tracks recency for eviction.
    this.buckets.delete(key);
    this.buckets.set(key, bucket);
    this.evictIfNeeded();
    if (bucket.tokens >= 1) {
      bucket.tokens -= 1;
      return { allowed: true, retryAfterSeconds: 0 };
    }
    const missing = 1 - bucket.tokens;
    return {
      allowed: false,
      retryAfterSeconds: Math.max(1, Math.ceil(missing / this.refillPerMs / 1000)),
    };
  }

  /**
   * Returns a token spent on a request that never reached FCM, so a retry
   * after a server error does not cost the ticket twice.
   */
  refund(key: string): void {
    const bucket = this.buckets.get(key);
    if (bucket !== undefined) {
      bucket.tokens = Math.min(this.burst, bucket.tokens + 1);
    }
  }

  /** Number of tracked keys, for tests. */
  get size(): number {
    return this.buckets.size;
  }

  private evictIfNeeded(): void {
    while (this.buckets.size > this.maxEntries) {
      const oldest = this.buckets.keys().next();
      if (oldest.done === true) {
        return;
      }
      this.buckets.delete(oldest.value);
    }
  }
}

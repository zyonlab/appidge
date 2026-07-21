// 轻量限速（滥用保护）——固定窗口，按 client IP + 路由 计数。
// per-isolate 内存实现，MVP 足够；不是强防护，只做基础节流。CORS 不是鉴权，限速是必需项。
// 可注入，测试用极小阈值命中 rate_limited 分支。

export interface RateLimiter {
  check(key: string): boolean; // true = 放行；false = 超限
}

interface Bucket {
  count: number;
  resetAt: number;
}

export class FixedWindowRateLimiter implements RateLimiter {
  private buckets = new Map<string, Bucket>();
  constructor(
    private readonly max: number,
    private readonly windowMs: number,
    private readonly now: () => number = Date.now,
  ) {}

  check(key: string): boolean {
    const t = this.now();
    const b = this.buckets.get(key);
    if (!b || t >= b.resetAt) {
      this.buckets.set(key, { count: 1, resetAt: t + this.windowMs });
      return true;
    }
    if (b.count >= this.max) return false;
    b.count += 1;
    return true;
  }
}

export function clientKey(req: Request, route: string): string {
  const ip =
    req.headers.get("cf-connecting-ip") ??
    req.headers.get("x-forwarded-for") ??
    "unknown";
  return `${ip}:${route}`;
}

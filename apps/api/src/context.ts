// 应用上下文 —— 依赖注入边界。所有外部副作用（Creem、时钟、限速、日志）走这里，
// 便于测试注入 mock（Core reducer 之外的等价隔离）。
import type { Env } from "./env";
import { isMockMode, intVar } from "./env";
import type { LicenseClient } from "./creem/client";
import { MockCreemClient } from "./creem/mock";
import { HttpCreemClient } from "./creem/http";
import { createLogger, type Logger } from "./log";
import { FixedWindowRateLimiter, type RateLimiter } from "./ratelimit";

export interface AppContext {
  env: Env;
  license: LicenseClient;
  logger: Logger;
  rateLimiter: RateLimiter;
  now: () => Date;
}

// 每个 isolate 维持一个限速器（跨请求累计）。以配置为键，避免测试间串味。
const limiterCache = new Map<string, RateLimiter>();

export function buildContext(env: Env, overrides?: Partial<AppContext>): AppContext {
  const mock = isMockMode(env);
  const now = overrides?.now ?? (() => new Date());
  const license: LicenseClient =
    overrides?.license ??
    (mock ? new MockCreemClient() : new HttpCreemClient(env.CREEM_API_BASE, env.CREEM_API_KEY, now));

  const max = intVar(env.RATE_LIMIT_MAX, 60);
  const windowMs = intVar(env.RATE_LIMIT_WINDOW_MS, 60000);
  const limiterKey = `${max}:${windowMs}`;
  let rateLimiter = overrides?.rateLimiter;
  if (!rateLimiter) {
    rateLimiter = limiterCache.get(limiterKey);
    if (!rateLimiter) {
      rateLimiter = new FixedWindowRateLimiter(max, windowMs);
      limiterCache.set(limiterKey, rateLimiter);
    }
  }

  const secrets = [env.CREEM_API_KEY, env.CREEM_WEBHOOK_SECRET, env.LICENSE_HMAC_PEPPER].filter(Boolean);

  return {
    env,
    license,
    logger: overrides?.logger ?? createLogger(secrets),
    rateLimiter,
    now,
  };
}

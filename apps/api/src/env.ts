// Env — Worker 绑定与非秘密变量。secret 只从 binding 注入，绝不硬编码。
export interface Env {
  DB: D1Database;

  // 开关 / 非秘密配置（wrangler.toml [vars]）
  MOCK_MODE: string; // "true" | "false"
  CREEM_API_BASE: string;
  CREEM_PRODUCT_ID: string;
  RATE_LIMIT_MAX: string;
  RATE_LIMIT_WINDOW_MS: string;
  MAX_BODY_BYTES: string;

  // secrets（本地 .dev.vars / 线上 wrangler secret）——绝不记录原值
  CREEM_API_KEY: string;
  CREEM_WEBHOOK_SECRET: string;
  LICENSE_HMAC_PEPPER: string;
}

export function isMockMode(env: Env): boolean {
  return String(env.MOCK_MODE).toLowerCase() !== "false";
}

export function intVar(value: string | undefined, fallback: number): number {
  const n = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

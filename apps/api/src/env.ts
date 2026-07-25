// Env — Worker 绑定与非秘密变量。secret 只从 binding 注入，绝不硬编码。
export interface Env {
  DB: D1Database;

  // 开关 / 非秘密配置（wrangler.toml [vars]）
  MOCK_MODE: string; // "true" | "false"
  CREEM_API_BASE: string; // test: https://test-api.creem.io / prod: https://api.creem.io
  CREEM_PRODUCT_ID: string; // 白名单：只处理本产品的 webhook 事件
  RATE_LIMIT_MAX: string;
  RATE_LIMIT_WINDOW_MS: string;
  MAX_BODY_BYTES: string;

  // secrets（本地 .dev.vars / 线上 wrangler secret）——绝不记录原值
  CREEM_API_KEY: string; // x-api-key 头（test 形如 creem_test_<alnum>；live 只有一段 creem_<alnum>）
  CREEM_WEBHOOK_SECRET: string; // creem-signature HMAC 密钥（Dashboard 字面值，whsec_ 前缀不剥离）
  LICENSE_HMAC_PEPPER: string;
}

export function isMockMode(env: Env): boolean {
  return String(env.MOCK_MODE).toLowerCase() !== "false";
}

export function intVar(value: string | undefined, fallback: number): number {
  const n = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

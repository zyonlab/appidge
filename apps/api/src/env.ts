// Env — Worker 绑定与非秘密变量。secret 只从 binding 注入，绝不硬编码。
export interface Env {
  DB: D1Database;

  // 开关 / 非秘密配置（wrangler.toml [vars]）
  MOCK_MODE: string; // "true" | "false"
  POLAR_API_BASE: string; // sandbox: https://sandbox-api.polar.sh / prod: https://api.polar.sh
  POLAR_ORGANIZATION_ID: string; // 每次 license API 调用必带（非秘密）
  POLAR_PRODUCT_ID: string; // 白名单：只接受本产品的 order webhook
  POLAR_BENEFIT_ID: string; // 白名单：只接受本 license-key benefit 的 grant webhook
  RATE_LIMIT_MAX: string;
  RATE_LIMIT_WINDOW_MS: string;
  MAX_BODY_BYTES: string;

  // secrets（本地 .dev.vars / 线上 wrangler secret）——绝不记录原值
  POLAR_ACCESS_TOKEN: string; // Authorization: Bearer <token>
  POLAR_WEBHOOK_SECRET: string; // Standard Webhooks 签名密钥
  LICENSE_HMAC_PEPPER: string;
}

export function isMockMode(env: Env): boolean {
  return String(env.MOCK_MODE).toLowerCase() !== "false";
}

export function intVar(value: string | undefined, fallback: number): number {
  const n = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

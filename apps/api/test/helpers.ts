import { env } from "cloudflare:test";
import { buildContext, type AppContext } from "../src/context";
import { signWebhook } from "../src/crypto";

// 建表（每个测试前调用；isolatedStorage 默认每测试隔离，需重建 schema）。
export async function resetSchema(): Promise<void> {
  // 先清（若存在）再建，确保干净。
  await env.DB.prepare("DROP TABLE IF EXISTS webhook_events").run();
  await env.DB.prepare("DROP TABLE IF EXISTS entitlements").run();
  for (const stmt of env.TEST_DDL) {
    await env.DB.prepare(stmt).run();
  }
}

// 固定时钟，便于断言 validatedAt / 时间字段。
export function fixedClock(iso: string): () => Date {
  return () => new Date(iso);
}

export function ctxWith(overrides?: Partial<AppContext>): AppContext {
  return buildContext(env, overrides);
}

// 构造已正确 HMAC 签名的 webhook 请求。
export async function signedWebhookRequest(bodyObj: unknown): Promise<Request> {
  const raw = new TextEncoder().encode(JSON.stringify(bodyObj));
  const sig = await signWebhook(env.CREEM_WEBHOOK_SECRET, raw);
  return new Request("https://api.appidge.app/v1/webhooks/creem", {
    method: "POST",
    headers: { "content-type": "application/json", "creem-signature": sig },
    body: raw,
  });
}

export function jsonPost(path: string, bodyObj: unknown, headers?: Record<string, string>): Request {
  return new Request(`https://api.appidge.app${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(headers ?? {}) },
    body: JSON.stringify(bodyObj),
  });
}

import { env } from "cloudflare:test";
import { buildContext, type AppContext } from "../src/context";
import { signStandardWebhook } from "../src/crypto";

// 建表（每个测试前调用；isolatedStorage 默认每测试隔离，需重建 schema）。
export async function resetSchema(): Promise<void> {
  // 先清（若存在）再建，确保干净。
  await env.DB.prepare("DROP TABLE IF EXISTS webhook_events").run();
  await env.DB.prepare("DROP TABLE IF EXISTS entitlements").run();
  await env.DB.prepare("DROP TABLE IF EXISTS refund_tombstones").run();
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

// 构造已正确签名的 Polar Standard Webhooks 请求。
// webhookId 稳定（重放/幂等测试复用同一 id）；timestamp 默认取当前真实时间，
// 以通过 handler 的 ±5min 漂移校验（默认 ctx 用真实时钟）。
export async function signedWebhookRequest(
  bodyObj: unknown,
  opts?: { webhookId?: string; timestampMs?: number; secret?: string; rawOverride?: Uint8Array },
): Promise<Request> {
  const raw = opts?.rawOverride ?? new TextEncoder().encode(JSON.stringify(bodyObj));
  const webhookId = opts?.webhookId ?? "msg_test_default";
  const ts = Math.floor((opts?.timestampMs ?? Date.now()) / 1000).toString();
  const secret = opts?.secret ?? env.POLAR_WEBHOOK_SECRET;
  const sig = await signStandardWebhook(secret, webhookId, ts, raw);
  return new Request("https://api.appidge.com/v1/webhooks/polar", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "webhook-id": webhookId,
      "webhook-timestamp": ts,
      "webhook-signature": sig,
    },
    body: raw,
  });
}

export function jsonPost(path: string, bodyObj: unknown, headers?: Record<string, string>): Request {
  return new Request(`https://api.appidge.com${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(headers ?? {}) },
    body: JSON.stringify(bodyObj),
  });
}

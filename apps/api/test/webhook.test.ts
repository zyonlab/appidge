import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { handleRequest } from "../src/index";
import { ctxWith, resetSchema, signedWebhookRequest, fixedClock } from "./helpers";
import { signStandardWebhook } from "../src/crypto";
import { getEntitlementByLicenseKeyId, getRefundTombstoneByOrder } from "../src/db";

const CLOCK = "2026-07-22T00:00:00Z";
const CLOCK_MS = Date.parse(CLOCK);
const LK_ID = "lk_test_primary";

function ctx() {
  return ctxWith({ now: fixedClock(CLOCK) });
}

// Polar 事件信封 { type, timestamp, data }。
function grantEvent(
  type: "benefit_grant.created" | "benefit_grant.revoked",
  o: Partial<{ licenseKeyId: string; order: string; customer: string; benefit: string }> = {},
) {
  return {
    type,
    timestamp: CLOCK,
    data: {
      id: "bg_MOCK_0001",
      order_id: o.order ?? "ord_MOCK_0001",
      customer_id: o.customer ?? "cust_MOCK_0001",
      benefit_id: o.benefit ?? env.POLAR_BENEFIT_ID,
      is_revoked: type === "benefit_grant.revoked",
      properties: { license_key_id: o.licenseKeyId ?? LK_ID, display_key: "XXXX-1234" },
    },
  };
}

function orderRefundEvent(o: Partial<{ order: string; customer: string; product: string }> = {}) {
  return {
    type: "order.refunded",
    timestamp: CLOCK,
    data: {
      id: o.order ?? "ord_MOCK_0001",
      customer_id: o.customer ?? "cust_MOCK_0001",
      product_id: o.product ?? env.POLAR_PRODUCT_ID,
    },
  };
}

// webhookId 唯一 → 一次投递；复用同一 id 模拟重投。timestamp 对齐固定时钟以通过漂移校验。
async function post(payload: unknown, webhookId = "msg_default") {
  const req = await signedWebhookRequest(payload, { webhookId, timestampMs: CLOCK_MS });
  return handleRequest(req, ctx());
}

async function entOf(lkId = LK_ID) {
  return getEntitlementByLicenseKeyId(env.DB, lkId);
}

describe("webhook signature verification (Standard Webhooks)", () => {
  beforeEach(async () => resetSchema());

  it("valid signature → 200, benefit_grant.created creates active entitlement", async () => {
    const res = await post(grantEvent("benefit_grant.created"), "msg_ok_1");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ received: true });
    expect((await entOf())?.status).toBe("active");
  });

  it("missing signature headers → 401", async () => {
    const req = new Request("https://api.appidge.com/v1/webhooks/polar", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(grantEvent("benefit_grant.created")),
    });
    expect((await handleRequest(req, ctx())).status).toBe(401);
  });

  it("tampered body (one raw byte) with original signature → 401", async () => {
    const raw = new TextEncoder().encode(JSON.stringify(grantEvent("benefit_grant.created")));
    const ts = Math.floor(CLOCK_MS / 1000).toString();
    const sig = await signStandardWebhook(env.POLAR_WEBHOOK_SECRET, "msg_tb", ts, raw);
    const tampered = raw.slice();
    tampered[15] = tampered[15] ^ 0x01;
    const req = new Request("https://api.appidge.com/v1/webhooks/polar", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "webhook-id": "msg_tb",
        "webhook-timestamp": ts,
        "webhook-signature": sig,
      },
      body: tampered,
    });
    expect((await handleRequest(req, ctx())).status).toBe(401);
  });

  it("tampered signature (one char) → 401", async () => {
    const raw = new TextEncoder().encode(JSON.stringify(grantEvent("benefit_grant.created")));
    const ts = Math.floor(CLOCK_MS / 1000).toString();
    const sig = await signStandardWebhook(env.POLAR_WEBHOOK_SECRET, "msg_ts", ts, raw);
    const badSig = sig.slice(0, -2) + (sig.endsWith("A") ? "B" : "A");
    const req = new Request("https://api.appidge.com/v1/webhooks/polar", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "webhook-id": "msg_ts",
        "webhook-timestamp": ts,
        "webhook-signature": badSig,
      },
      body: raw,
    });
    expect((await handleRequest(req, ctx())).status).toBe(401);
  });

  it("stale timestamp (beyond tolerance) → 401 (replay protection)", async () => {
    // 正确签名，但时间戳比固定时钟早 1 小时 → 超过 ±5min 漂移窗口。
    const req = await signedWebhookRequest(grantEvent("benefit_grant.created"), {
      webhookId: "msg_stale",
      timestampMs: CLOCK_MS - 3600_000,
    });
    expect((await handleRequest(req, ctx())).status).toBe(401);
  });
});

describe("webhook idempotency & ordering", () => {
  beforeEach(async () => resetSchema());

  it("replay same webhook-id → 200 twice, single side effect", async () => {
    const ev = grantEvent("benefit_grant.created");
    expect((await post(ev, "msg_dup")).status).toBe(200);
    expect((await post(ev, "msg_dup")).status).toBe(200);
    const rows = await env.DB.prepare("SELECT count(*) AS n FROM webhook_events WHERE event_id = ?")
      .bind("msg_dup")
      .first<{ n: number }>();
    expect(rows?.n).toBe(1);
  });

  it("revoke BEFORE grant (out of order) → stays revoked", async () => {
    await post(grantEvent("benefit_grant.revoked"), "msg_rev_first");
    expect((await entOf())?.status).toBe("revoked");
    await post(grantEvent("benefit_grant.created"), "msg_grant_after");
    expect((await entOf())?.status).toBe("revoked"); // 不得翻回 active
  });

  it("benefit_grant.revoked → per-license revoke by license_key_id", async () => {
    await post(grantEvent("benefit_grant.created"), "msg_g1");
    expect((await entOf())?.status).toBe("active");
    await post(grantEvent("benefit_grant.revoked"), "msg_r1");
    const ent = await entOf();
    expect(ent?.status).toBe("revoked");
    expect(ent?.reason).toBe("revoked");
  });

  it("order.refunded revokes existing order row (backup path)", async () => {
    await post(grantEvent("benefit_grant.created", { order: "ord_X" }), "msg_g2");
    await post(orderRefundEvent({ order: "ord_X" }), "msg_ref2");
    const ent = await entOf();
    expect(ent?.status).toBe("revoked");
    expect(ent?.reason).toBe("refund");
  });

  it("order.refunded BEFORE grant persists a tombstone and the later grant is born revoked", async () => {
    await post(orderRefundEvent({ order: "ord_REFUND_FIRST" }), "msg_refund_first");
    expect(await getRefundTombstoneByOrder(env.DB, "ord_REFUND_FIRST")).toMatchObject({
      order_id: "ord_REFUND_FIRST",
      reason: "refund",
      source_event_id: "msg_refund_first",
    });
    expect(await entOf()).toBeNull();

    await post(grantEvent("benefit_grant.created", { order: "ord_REFUND_FIRST" }), "msg_grant_late");
    const ent = await entOf();
    expect(ent?.status).toBe("revoked");
    expect(ent?.reason).toBe("refund");
  });
});

describe("webhook safe-ignore & validation", () => {
  beforeEach(async () => resetSchema());

  it("unknown event type → 200, no entitlement", async () => {
    const res = await post({ type: "subscription.trialing", timestamp: CLOCK, data: {} }, "msg_unk");
    expect(res.status).toBe(200);
    expect(await entOf()).toBeNull();
  });

  it("unknown benefit → 200, safely ignored (no entitlement)", async () => {
    const res = await post(grantEvent("benefit_grant.created", { benefit: "ben_SOMEONE_ELSE" }), "msg_wrongben");
    expect(res.status).toBe(200);
    expect(await entOf()).toBeNull();
  });

  it("malformed JSON after valid signature → 400", async () => {
    const raw = new TextEncoder().encode("{ not json");
    const ts = Math.floor(CLOCK_MS / 1000).toString();
    const sig = await signStandardWebhook(env.POLAR_WEBHOOK_SECRET, "msg_bad", ts, raw);
    const req = new Request("https://api.appidge.com/v1/webhooks/polar", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "webhook-id": "msg_bad",
        "webhook-timestamp": ts,
        "webhook-signature": sig,
      },
      body: raw,
    });
    expect((await handleRequest(req, ctx())).status).toBe(400);
  });

  it("missing webhook-id → 401 (cannot verify without it)", async () => {
    const raw = new TextEncoder().encode(JSON.stringify(grantEvent("benefit_grant.created")));
    const ts = Math.floor(CLOCK_MS / 1000).toString();
    // 无 webhook-id 头 → 验签直接失败
    const req = new Request("https://api.appidge.com/v1/webhooks/polar", {
      method: "POST",
      headers: { "content-type": "application/json", "webhook-timestamp": ts, "webhook-signature": "v1,AAAA" },
      body: raw,
    });
    expect((await handleRequest(req, ctx())).status).toBe(401);
  });
});

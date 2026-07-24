import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { handleRequest } from "../src/index";
import { ctxWith, resetSchema, signedWebhookRequest, fixedClock } from "./helpers";
import { signCreemWebhook } from "../src/crypto";
import {
  getEntitlementByLicenseKeyId,
  getRefundTombstoneByOrder,
  upsertActiveEntitlement,
} from "../src/db";

const CLOCK = "2026-07-22T00:00:00Z";
const ORDER = "ord_TESTXXXXXXXXXXXXXXXXXX";

function ctx() {
  return ctxWith({ now: fixedClock(CLOCK) });
}

// ── Creem 事件信封（对齐 contracts/fixtures/creem/*.json 的真实 test mode 捕获）：
//    顶层 { id: "evt_...", eventType, created_at, object }；业务字段在 object 下。
//    checkout.completed：object.order.{id,product,customer} + object.product.id
//    refund/dispute    ：object.order.{id,product,customer}（order 为嵌套对象）
function checkoutEvent(eventId: string, o: Partial<{ order: string; product: string }> = {}) {
  const product = o.product ?? env.CREEM_PRODUCT_ID;
  return {
    id: eventId,
    eventType: "checkout.completed",
    created_at: Date.parse(CLOCK),
    object: {
      id: "ch_TESTXXXXXXXXXXXXXXXXXX",
      object: "checkout",
      order: {
        object: "order",
        id: o.order ?? ORDER,
        customer: "cust_TESTXXXXXXXXXXXXXXXX",
        product,
        status: "paid",
        mode: "test",
      },
      product: { id: product, object: "product", mode: "test" },
      customer: { id: "cust_TESTXXXXXXXXXXXXXXXX", object: "customer", mode: "test" },
      status: "completed",
      mode: "test",
    },
  };
}

function refundLikeEvent(
  eventType: "refund.created" | "dispute.created",
  eventId: string,
  o: Partial<{ order: string; product: string }> = {},
) {
  return {
    id: eventId,
    eventType,
    created_at: Date.parse(CLOCK),
    object: {
      id: eventType === "refund.created" ? "ref_TESTXXXXXXXXXXXXXXXXX" : "disp_TESTXXXXXXXXXXXXXXXX",
      object: eventType === "refund.created" ? "refund" : "dispute",
      order: {
        object: "order",
        id: o.order ?? ORDER,
        customer: "cust_TESTXXXXXXXXXXXXXXXX",
        product: o.product ?? env.CREEM_PRODUCT_ID,
        status: "paid",
        mode: "test",
      },
      customer: { id: "cust_TESTXXXXXXXXXXXXXXXX", object: "customer", mode: "test" },
      mode: "test",
    },
  };
}

async function post(payload: unknown) {
  const req = await signedWebhookRequest(payload);
  return handleRequest(req, ctx());
}

async function eventCount(eventId: string): Promise<number> {
  const row = await env.DB.prepare("SELECT count(*) AS n FROM webhook_events WHERE event_id = ?")
    .bind(eventId)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

// 模拟 app 路径已建立的 entitlement（Creem webhook 不带 license，entitlement 行只能由
// activate/validate 惰性登记；order_id 列保留给未来 payload 若补 order↔license 映射时用）。
async function seedEntitlement(licenseKeyId: string, orderId: string) {
  await upsertActiveEntitlement(env.DB, {
    licenseKeyId,
    orderId,
    customerId: "cust_TESTXXXXXXXXXXXXXXXX",
    productId: env.CREEM_PRODUCT_ID,
    sourceEventId: "evt_seed",
    now: CLOCK,
  });
}

describe("webhook signature verification (creem-signature, HMAC-SHA256 hex over raw body)", () => {
  beforeEach(async () => resetSchema());

  it("valid signature → 200 received, event registered (checkout.completed is audit-only)", async () => {
    const res = await post(checkoutEvent("evt_ok_1"));
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ received: true });
    expect(await eventCount("evt_ok_1")).toBe(1);
    // Creem webhook 不携带 license key → 不建 entitlement（吊销主路走 validate）
    const n = await env.DB.prepare("SELECT count(*) AS n FROM entitlements").first<{ n: number }>();
    expect(n?.n).toBe(0);
  });

  it("missing creem-signature header → 401", async () => {
    const req = new Request("https://api.appidge.com/v1/webhooks/creem", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(checkoutEvent("evt_nosig")),
    });
    expect((await handleRequest(req, ctx())).status).toBe(401);
  });

  it("tampered body (one raw byte) with original signature → 401", async () => {
    const raw = new TextEncoder().encode(JSON.stringify(checkoutEvent("evt_tb")));
    const sig = await signCreemWebhook(env.CREEM_WEBHOOK_SECRET, raw);
    const tampered = raw.slice();
    tampered[15] = tampered[15] ^ 0x01;
    const req = new Request("https://api.appidge.com/v1/webhooks/creem", {
      method: "POST",
      headers: { "content-type": "application/json", "creem-signature": sig },
      body: tampered,
    });
    expect((await handleRequest(req, ctx())).status).toBe(401);
  });

  it("tampered signature (one char) → 401", async () => {
    const raw = new TextEncoder().encode(JSON.stringify(checkoutEvent("evt_ts")));
    const sig = await signCreemWebhook(env.CREEM_WEBHOOK_SECRET, raw);
    const badSig = sig.slice(0, -1) + (sig.endsWith("a") ? "b" : "a");
    const req = new Request("https://api.appidge.com/v1/webhooks/creem", {
      method: "POST",
      headers: { "content-type": "application/json", "creem-signature": badSig },
      body: raw,
    });
    expect((await handleRequest(req, ctx())).status).toBe(401);
  });

  it("signature computed with wrong secret → 401", async () => {
    const req = await signedWebhookRequest(checkoutEvent("evt_wrongsecret"), {
      secret: "whsec_WRONG_secret_not_ours",
    });
    expect((await handleRequest(req, ctx())).status).toBe(401);
  });
});

describe("webhook idempotency & ordering", () => {
  beforeEach(async () => resetSchema());

  it("replay same event id → 200 twice, single registration (Creem 无时间戳头，重放防御=事件幂等)", async () => {
    const ev = checkoutEvent("evt_dup");
    expect((await post(ev)).status).toBe(200);
    expect((await post(ev)).status).toBe(200);
    expect(await eventCount("evt_dup")).toBe(1);
  });

  it("duplicate refund delivery → single tombstone side effect", async () => {
    const ev = refundLikeEvent("refund.created", "evt_ref_dup", { order: "ord_DUP" });
    await post(ev);
    await post(ev);
    expect(await eventCount("evt_ref_dup")).toBe(1);
    const ts = await getRefundTombstoneByOrder(env.DB, "ord_DUP");
    expect(ts).toMatchObject({ order_id: "ord_DUP", reason: "refund", source_event_id: "evt_ref_dup" });
  });

  it("refund.created revokes an existing order-linked entitlement", async () => {
    await seedEntitlement("lk_order_linked", "ord_X");
    await post(refundLikeEvent("refund.created", "evt_ref_1", { order: "ord_X" }));
    const ent = await getEntitlementByLicenseKeyId(env.DB, "lk_order_linked");
    expect(ent?.status).toBe("revoked");
    expect(ent?.reason).toBe("refund");
  });

  it("dispute.created revokes with reason=dispute", async () => {
    await seedEntitlement("lk_disputed", "ord_D");
    await post(refundLikeEvent("dispute.created", "evt_disp_1", { order: "ord_D" }));
    const ent = await getEntitlementByLicenseKeyId(env.DB, "lk_disputed");
    expect(ent?.status).toBe("revoked");
    expect(ent?.reason).toBe("dispute");
  });

  it("refund BEFORE checkout (out of order) → tombstone persists; later checkout creates nothing active", async () => {
    await post(refundLikeEvent("refund.created", "evt_refund_first", { order: "ord_REFUND_FIRST" }));
    expect(await getRefundTombstoneByOrder(env.DB, "ord_REFUND_FIRST")).toMatchObject({
      order_id: "ord_REFUND_FIRST",
      reason: "refund",
      source_event_id: "evt_refund_first",
    });

    // 随后的 checkout.completed（无 license key）不建任何 active entitlement。
    const res = await post(checkoutEvent("evt_checkout_late", { order: "ord_REFUND_FIRST" }));
    expect(res.status).toBe(200);
    const n = await env.DB.prepare("SELECT count(*) AS n FROM entitlements WHERE status = 'active'").first<{
      n: number;
    }>();
    expect(n?.n).toBe(0);
  });

  it("out-of-order at the DB layer: a grant arriving after the tombstone is born revoked", async () => {
    // 保障不变量：无论授予路径何时补上 order↔license 映射，退款订单绝不产生 active 行。
    await post(refundLikeEvent("refund.created", "evt_tomb_1", { order: "ord_TOMB" }));
    await seedEntitlement("lk_late_grant", "ord_TOMB");
    const ent = await getEntitlementByLicenseKeyId(env.DB, "lk_late_grant");
    expect(ent?.status).toBe("revoked");
    expect(ent?.reason).toBe("refund");
  });
});

describe("webhook safe-ignore & validation", () => {
  beforeEach(async () => resetSchema());

  it("unknown event type → 200, registered, no side effects", async () => {
    const res = await post({
      id: "evt_unknown",
      eventType: "subscription.paid",
      created_at: Date.parse(CLOCK),
      object: {},
    });
    expect(res.status).toBe(200);
    expect(await eventCount("evt_unknown")).toBe(1);
  });

  it("unknown product on checkout → 200, safely ignored", async () => {
    const res = await post(checkoutEvent("evt_wrongprod", { product: "prod_SOMEONE_ELSE" }));
    expect(res.status).toBe(200);
    expect(await eventCount("evt_wrongprod")).toBe(1);
  });

  it("unknown product on refund → 200, no tombstone", async () => {
    const res = await post(
      refundLikeEvent("refund.created", "evt_wrongprod_ref", { order: "ord_OTHER", product: "prod_SOMEONE_ELSE" }),
    );
    expect(res.status).toBe(200);
    expect(await getRefundTombstoneByOrder(env.DB, "ord_OTHER")).toBeNull();
  });

  it("malformed JSON after valid signature → 400", async () => {
    const raw = new TextEncoder().encode("{ not json");
    const sig = await signCreemWebhook(env.CREEM_WEBHOOK_SECRET, raw);
    const req = new Request("https://api.appidge.com/v1/webhooks/creem", {
      method: "POST",
      headers: { "content-type": "application/json", "creem-signature": sig },
      body: raw,
    });
    expect((await handleRequest(req, ctx())).status).toBe(400);
  });

  it("payload without event id → 400 (cannot be idempotent)", async () => {
    const res = await post({ eventType: "checkout.completed", object: {} });
    expect(res.status).toBe(400);
  });
});

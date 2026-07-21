import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { handleRequest } from "../src/index";
import { ctxWith, resetSchema, signedWebhookRequest, fixedClock } from "./helpers";
import { signWebhook, licenseFingerprint } from "../src/crypto";
import { getEntitlement } from "../src/db";

const CLOCK = "2026-02-01T00:00:00Z";
const LICENSE = "MOCK-LICENSE-0000-0000-0000";

function ctx() {
  return ctxWith({ now: fixedClock(CLOCK) });
}

function event(
  type: string,
  overrides: Partial<{ id: string; license: string | null; order: string; customer: string; product: string }> = {},
) {
  // license: 省略 → 默认 LICENSE；显式传 null → 真正不带 license（测 order-only 分支）。
  const withLicense = !("license" in overrides) || overrides.license != null;
  return {
    id: overrides.id ?? `evt_${type}_0001`,
    eventType: type,
    object: {
      order: overrides.order ?? "ord_MOCK_0001",
      customer: overrides.customer ?? "cust_MOCK_0001",
      product: overrides.product ?? env.CREEM_PRODUCT_ID,
      ...(withLicense ? { license: overrides.license ?? LICENSE } : {}),
    },
  };
}

async function post(payload: unknown) {
  return handleRequest(await signedWebhookRequest(payload), ctx());
}

async function fpOf(license: string) {
  return licenseFingerprint(env.LICENSE_HMAC_PEPPER, license);
}

describe("webhook signature verification", () => {
  beforeEach(async () => resetSchema());

  it("valid signature → 200 received, checkout creates active entitlement", async () => {
    const res = await post(event("checkout.completed"));
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ received: true });
    const ent = await getEntitlement(env.DB, await fpOf(LICENSE));
    expect(ent?.status).toBe("active");
  });

  it("missing signature → 401", async () => {
    const req = new Request("https://api.appidge.app/v1/webhooks/creem", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(event("checkout.completed")),
    });
    const res = await handleRequest(req, ctx());
    expect(res.status).toBe(401);
  });

  it("tampered body (one raw byte) with original signature → 401", async () => {
    const payload = event("checkout.completed");
    const raw = new TextEncoder().encode(JSON.stringify(payload));
    const sig = await signWebhook(env.CREEM_WEBHOOK_SECRET, raw);
    const tampered = raw.slice();
    tampered[10] = tampered[10] ^ 0x01; // 翻一个字节
    const req = new Request("https://api.appidge.app/v1/webhooks/creem", {
      method: "POST",
      headers: { "content-type": "application/json", "creem-signature": sig },
      body: tampered,
    });
    const res = await handleRequest(req, ctx());
    expect(res.status).toBe(401);
  });

  it("tampered signature (one hex char) → 401", async () => {
    const payload = event("checkout.completed");
    const raw = new TextEncoder().encode(JSON.stringify(payload));
    const sig = await signWebhook(env.CREEM_WEBHOOK_SECRET, raw);
    const badSig = (sig[0] === "a" ? "b" : "a") + sig.slice(1);
    const req = new Request("https://api.appidge.app/v1/webhooks/creem", {
      method: "POST",
      headers: { "content-type": "application/json", "creem-signature": badSig },
      body: raw,
    });
    const res = await handleRequest(req, ctx());
    expect(res.status).toBe(401);
  });
});

describe("webhook idempotency & ordering", () => {
  beforeEach(async () => resetSchema());

  it("replay same event id → 200 twice, single side effect", async () => {
    const ev = event("checkout.completed", { id: "evt_dup_1" });
    const r1 = await post(ev);
    const r2 = await post(ev);
    expect(r1.status).toBe(200);
    expect(r2.status).toBe(200);
    const rows = await env.DB.prepare("SELECT count(*) AS n FROM webhook_events WHERE event_id = ?")
      .bind("evt_dup_1")
      .first<{ n: number }>();
    expect(rows?.n).toBe(1);
  });

  it("refund BEFORE checkout (out of order) → stays revoked", async () => {
    // refund 先到（带 license）→ 建 revoked 行
    await post(event("refund.created", { id: "evt_refund_1" }));
    let ent = await getEntitlement(env.DB, await fpOf(LICENSE));
    expect(ent?.status).toBe("revoked");
    // checkout 后到（同 license）→ 不得翻回 active
    await post(event("checkout.completed", { id: "evt_checkout_1" }));
    ent = await getEntitlement(env.DB, await fpOf(LICENSE));
    expect(ent?.status).toBe("revoked");
  });

  it("duplicate checkout after revoke does not re-activate", async () => {
    const checkout = event("checkout.completed", { id: "evt_c2" });
    await post(checkout); // active
    await post(event("refund.created", { id: "evt_r2" })); // revoked
    await post(checkout); // 重复投递，已 processed → 不再执行副作用
    const ent = await getEntitlement(env.DB, await fpOf(LICENSE));
    expect(ent?.status).toBe("revoked");
  });

  it("dispute.created → revoked", async () => {
    await post(event("checkout.completed", { id: "evt_c3" }));
    await post(event("dispute.created", { id: "evt_d3" }));
    const ent = await getEntitlement(env.DB, await fpOf(LICENSE));
    expect(ent?.status).toBe("revoked");
    expect(ent?.reason).toBe("dispute");
  });

  it("refund with order only (no license) revokes existing order row", async () => {
    await post(event("checkout.completed", { id: "evt_c4", order: "ord_X" }));
    // refund 不带 license，只带 order（license:null → 真正省略）
    await post(event("refund.created", { id: "evt_r4", order: "ord_X", license: null }));
    const ent = await getEntitlement(env.DB, await fpOf(LICENSE));
    expect(ent?.status).toBe("revoked");
    expect(ent?.reason).toBe("refund");
  });
});

describe("webhook safe-ignore & validation", () => {
  beforeEach(async () => resetSchema());

  it("unknown event type → 200, no entitlement", async () => {
    const res = await post(event("subscription.trialing", { id: "evt_unknown_1" }));
    expect(res.status).toBe(200);
    const ent = await getEntitlement(env.DB, await fpOf(LICENSE));
    expect(ent).toBeNull();
  });

  it("unknown product → 200, safely ignored (no entitlement)", async () => {
    const res = await post(event("checkout.completed", { id: "evt_wrongprod", product: "prod_SOMEONE_ELSE" }));
    expect(res.status).toBe(200);
    const ent = await getEntitlement(env.DB, await fpOf(LICENSE));
    expect(ent).toBeNull();
  });

  it("malformed JSON after valid signature → 400", async () => {
    const raw = new TextEncoder().encode("{ not json");
    const sig = await signWebhook(env.CREEM_WEBHOOK_SECRET, raw);
    const req = new Request("https://api.appidge.app/v1/webhooks/creem", {
      method: "POST",
      headers: { "content-type": "application/json", "creem-signature": sig },
      body: raw,
    });
    const res = await handleRequest(req, ctx());
    expect(res.status).toBe(400);
  });

  it("missing event id → 400", async () => {
    const res = await post({ eventType: "checkout.completed", object: { license: LICENSE } });
    expect(res.status).toBe(400);
  });
});

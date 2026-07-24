import { describe, it, expect, beforeEach, vi, afterEach } from "vitest";
import { env } from "cloudflare:test";
import { handleRequest } from "../src/index";
import { ctxWith, resetSchema, fixedClock, jsonPost, signedWebhookRequest } from "./helpers";
import { redact } from "../src/log";

const CLOCK = "2026-07-22T00:00:00Z";
const LICENSE = "MOCK-LICENSE-DEADBEEF-SECRET-9999";

describe("redact()", () => {
  it("scrubs known secrets and creem-token patterns", () => {
    const out = redact({ apiKey: "creem_test_abcdef123456", note: "hello whsec_zzzzzzzz" }, [
      "creem_test_abcdef123456",
    ]);
    expect(out).not.toContain("creem_test_abcdef123456");
    expect(out).toContain("[REDACTED]");
    expect(out).not.toContain("whsec_zzzzzzzz");
  });

  it("scrubs live-key pattern even when not passed as a known secret", () => {
    const out = redact("oops creem_live_1234567890abc leaked", []);
    expect(out).not.toContain("creem_live_1234567890abc");
  });
});

describe("log redaction across handlers", () => {
  let logs: string[] = [];
  beforeEach(async () => {
    await resetSchema();
    logs = [];
    for (const m of ["log", "warn", "error"] as const) {
      vi.spyOn(console, m).mockImplementation((...args: unknown[]) => {
        logs.push(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" "));
      });
    }
  });
  afterEach(() => vi.restoreAllMocks());

  it("full license key and API key never appear in logs (happy + error paths)", async () => {
    // activate happy
    await handleRequest(
      jsonPost("/v1/licenses/activate", { licenseKey: LICENSE, instanceName: "n", appVersion: "1.0.0" }),
      ctxWith({ now: fixedClock(CLOCK) }),
    );
    // activate error path (upstream 5xx)
    await handleRequest(
      jsonPost("/v1/licenses/activate", {
        licenseKey: "MOCK-5XX-SECRET-9999",
        instanceName: "n",
        appVersion: "1.0.0",
      }),
      ctxWith({ now: fixedClock(CLOCK) }),
    );
    // webhook: checkout.completed（Creem payload 是订单中心，不含 license key）
    await handleRequest(
      await signedWebhookRequest({
        id: "evt_redact_1",
        eventType: "checkout.completed",
        created_at: Date.parse(CLOCK),
        object: {
          id: "ch_redact_1",
          object: "checkout",
          order: {
            object: "order",
            id: "ord_redact_1",
            customer: "cust_redact_1",
            product: env.CREEM_PRODUCT_ID,
            status: "paid",
            mode: "test",
          },
          product: { id: env.CREEM_PRODUCT_ID, object: "product", mode: "test" },
          status: "completed",
          mode: "test",
        },
      }),
      ctxWith({ now: fixedClock(CLOCK) }),
    );
    // bad signature (logs a warn)
    await handleRequest(
      new Request("https://api.appidge.com/v1/webhooks/creem", {
        method: "POST",
        headers: { "content-type": "application/json", "creem-signature": "deadbeef" },
        body: JSON.stringify({ id: "evt_bad", eventType: "refund.created", object: {} }),
      }),
      ctxWith({ now: fixedClock(CLOCK) }),
    );

    const all = logs.join("\n");
    expect(logs.length).toBeGreaterThan(0);
    expect(all).not.toContain(LICENSE);
    expect(all).not.toContain(env.CREEM_API_KEY);
    expect(all).not.toContain(env.CREEM_WEBHOOK_SECRET);
    expect(all).not.toContain(env.LICENSE_HMAC_PEPPER);
  });
});

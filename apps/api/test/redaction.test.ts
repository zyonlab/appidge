import { describe, it, expect, beforeEach, vi, afterEach } from "vitest";
import { env } from "cloudflare:test";
import { handleRequest } from "../src/index";
import { ctxWith, resetSchema, fixedClock, jsonPost, signedWebhookRequest } from "./helpers";
import { redact } from "../src/log";

const CLOCK = "2026-07-22T00:00:00Z";
const LICENSE = "MOCK-LICENSE-DEADBEEF-SECRET-9999";

describe("redact()", () => {
  it("scrubs known secrets and polar-token patterns", () => {
    const out = redact({ apiKey: "polar_oat_abcdef123456", note: "hello whsec_zzzzzzzz" }, ["polar_oat_abcdef123456"]);
    expect(out).not.toContain("polar_oat_abcdef123456");
    expect(out).toContain("[REDACTED]");
    expect(out).not.toContain("whsec_zzzzzzzz");
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

  it("full license key and access token never appear in logs (happy + error paths)", async () => {
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
    // webhook: benefit_grant.created（Polar 只携带 license_key_id，不含原始 key）
    await handleRequest(
      await signedWebhookRequest(
        {
          type: "benefit_grant.created",
          timestamp: CLOCK,
          data: {
            id: "bg_1",
            order_id: "ord_1",
            customer_id: "cust_1",
            benefit_id: env.POLAR_BENEFIT_ID,
            properties: { license_key_id: "lk_redact_1", display_key: "XXXX-9999" },
          },
        },
        { webhookId: "msg_redact_1", timestampMs: Date.parse(CLOCK) },
      ),
      ctxWith({ now: fixedClock(CLOCK) }),
    );
    // bad signature (logs a warn)
    await handleRequest(
      new Request("https://api.appidge.com/v1/webhooks/polar", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "webhook-id": "msg_bad",
          "webhook-timestamp": Math.floor(Date.parse(CLOCK) / 1000).toString(),
          "webhook-signature": "v1,deadbeef",
        },
        body: JSON.stringify({ type: "benefit_grant.revoked", timestamp: CLOCK, data: {} }),
      }),
      ctxWith({ now: fixedClock(CLOCK) }),
    );

    const all = logs.join("\n");
    expect(logs.length).toBeGreaterThan(0);
    expect(all).not.toContain(LICENSE);
    expect(all).not.toContain(env.POLAR_ACCESS_TOKEN);
    expect(all).not.toContain(env.POLAR_WEBHOOK_SECRET);
    expect(all).not.toContain(env.LICENSE_HMAC_PEPPER);
  });
});

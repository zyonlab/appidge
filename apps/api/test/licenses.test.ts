import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { handleRequest } from "../src/index";
import { ctxWith, resetSchema, fixedClock, jsonPost } from "./helpers";
import { licenseFingerprint } from "../src/crypto";
import { revokeByLicenseKeyId } from "../src/db";
import { FixedWindowRateLimiter } from "../src/ratelimit";
import { MockPolarClient } from "../src/polar/mock";
import activateSuccess from "../../../contracts/fixtures/facade/activate.success.json";
import errorActivationLimit from "../../../contracts/fixtures/facade/error.activation_limit.json";

const CLOCK = "2026-01-01T00:00:00Z";

async function call(path: string, body: unknown, overrides = {}) {
  return handleRequest(jsonPost(path, body), ctxWith({ now: fixedClock(CLOCK), ...overrides }));
}

describe("POST /v1/licenses/activate", () => {
  beforeEach(async () => resetSchema());

  it("happy path output deep-equals activate.success fixture", async () => {
    const res = await call("/v1/licenses/activate", activateSuccess.request);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual(activateSuccess.response);
  });

  it("maps upstream invalid license → invalid_license (402)", async () => {
    const res = await call("/v1/licenses/activate", {
      licenseKey: "MOCK-INVALID-0000-0000",
      instanceName: "n",
      appVersion: "1.0.0",
    });
    expect(res.status).toBe(402);
    expect(await res.json()).toMatchObject({ error: "invalid_license" });
  });

  it("maps activation limit → activation_limit (409) matching fixture shape", async () => {
    const res = await call("/v1/licenses/activate", {
      licenseKey: "MOCK-LIMIT-0000-0000",
      instanceName: "n",
      appVersion: "1.0.0",
    });
    expect(res.status).toBe(409);
    expect(await res.json()).toMatchObject({ error: errorActivationLimit.response.error });
  });

  it("maps upstream expired → expired (402)", async () => {
    const res = await call("/v1/licenses/activate", {
      licenseKey: "MOCK-EXPIRED-0000-0000",
      instanceName: "n",
      appVersion: "1.0.0",
    });
    expect(res.status).toBe(402);
    expect(await res.json()).toMatchObject({ error: "expired" });
  });

  it("maps upstream 429 → rate_limited (429)", async () => {
    const res = await call("/v1/licenses/activate", {
      licenseKey: "MOCK-RATELIMIT-0000",
      instanceName: "n",
      appVersion: "1.0.0",
    });
    expect(res.status).toBe(429);
    expect(await res.json()).toMatchObject({ error: "rate_limited" });
  });

  it("maps upstream 5xx → upstream_unavailable (502)", async () => {
    const res = await call("/v1/licenses/activate", {
      licenseKey: "MOCK-5XX-0000-0000",
      instanceName: "n",
      appVersion: "1.0.0",
    });
    expect(res.status).toBe(502);
    expect(await res.json()).toMatchObject({ error: "upstream_unavailable" });
  });

  it("maps upstream timeout → upstream_unavailable (502)", async () => {
    const res = await call("/v1/licenses/activate", {
      licenseKey: "MOCK-TIMEOUT-0000-0000",
      instanceName: "n",
      appVersion: "1.0.0",
    });
    expect(res.status).toBe(502);
    expect(await res.json()).toMatchObject({ error: "upstream_unavailable" });
  });

  it("revoke webhook BEFORE first activate still overrides an upstream active result", async () => {
    const licenseKey = "MOCK-LICENSE-0000-0000-0000";
    const upstream = await new MockPolarClient().validate(licenseKey, "inst_probe");
    await revokeByLicenseKeyId(env.DB, {
      licenseKeyId: upstream.licenseKeyId,
      orderId: "ord_before_activate",
      reason: "refund",
      sourceEventId: "evt_before_activate",
      now: CLOCK,
    });

    const res = await call("/v1/licenses/activate", {
      licenseKey,
      instanceName: "appidge-install-test",
      appVersion: "1.0.0",
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ status: "revoked" });
  });
});

describe("POST /v1/licenses/validate", () => {
  beforeEach(async () => resetSchema());

  it("happy path → active", async () => {
    const res = await call("/v1/licenses/validate", {
      licenseKey: "MOCK-LICENSE-0000-0000-0000",
      instanceId: "inst_MOCK_0000000000",
      appVersion: "1.0.0",
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { status: string; validatedAt: string };
    expect(body.status).toBe("active");
    expect(body.validatedAt).toBe(CLOCK);
  });

  it("upstream disabled → revoked in body (200)", async () => {
    const res = await call("/v1/licenses/validate", {
      licenseKey: "MOCK-DISABLED-0000-0000",
      instanceId: "inst_MOCK_0000000000",
      appVersion: "1.0.0",
    });
    expect(res.status).toBe(200);
    expect((await res.json() as { status: string }).status).toBe("revoked");
  });

  it("upstream expired → expired in body (200)", async () => {
    const res = await call("/v1/licenses/validate", {
      licenseKey: "MOCK-EXPIRED-0000-0000",
      instanceId: "inst_MOCK_0000000000",
      appVersion: "1.0.0",
    });
    expect(res.status).toBe(200);
    expect((await res.json() as { status: string }).status).toBe("expired");
  });

  it("LOCAL revoked overrides upstream active (webhook revoke by license_key_id → validate local-first)", async () => {
    const licenseKey = "MOCK-LICENSE-0000-0000-0000"; // upstream would say active
    const body = { licenseKey, instanceId: "inst_MOCK_0000000000", appVersion: "1.0.0" };
    // 1) 首次 validate：上游 active，惰性登记 fingerprint↔license_key_id 映射。
    const r1 = await call("/v1/licenses/validate", body);
    expect((await r1.json() as { status: string }).status).toBe("active");
    // 2) 取到该行 license_key_id，模拟 webhook 精确吊销（benefit_grant.revoked）。
    const fp = await licenseFingerprint(env.LICENSE_HMAC_PEPPER, licenseKey);
    const row = await env.DB.prepare("SELECT license_key_id FROM entitlements WHERE license_fingerprint = ?")
      .bind(fp)
      .first<{ license_key_id: string }>();
    expect(row?.license_key_id).toBeTruthy();
    await revokeByLicenseKeyId(env.DB, {
      licenseKeyId: row!.license_key_id,
      orderId: "ord_MOCK_0000",
      reason: "refund",
      sourceEventId: "evt_seed",
      now: CLOCK,
    });
    // 3) 再次 validate：本地 revoked 优先于上游 active。
    const r2 = await call("/v1/licenses/validate", body);
    expect(r2.status).toBe(200);
    expect((await r2.json() as { status: string }).status).toBe("revoked");
  });

  it("revoke webhook BEFORE first validate is rechecked after license_key_id mapping", async () => {
    const licenseKey = "MOCK-LICENSE-0000-0000-0000";
    const instanceId = "inst_MOCK_0000000000";
    const upstream = await new MockPolarClient().validate(licenseKey, instanceId);
    await revokeByLicenseKeyId(env.DB, {
      licenseKeyId: upstream.licenseKeyId,
      orderId: "ord_before_validate",
      reason: "refund",
      sourceEventId: "evt_before_validate",
      now: CLOCK,
    });

    const res = await call("/v1/licenses/validate", { licenseKey, instanceId, appVersion: "1.0.0" });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ status: "revoked" });
  });
});

describe("POST /v1/licenses/deactivate", () => {
  beforeEach(async () => resetSchema());

  it("happy path → deactivated", async () => {
    const res = await call("/v1/licenses/deactivate", {
      licenseKey: "MOCK-LICENSE-0000-0000-0000",
      instanceId: "inst_MOCK_0000000000",
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "deactivated" });
  });

  it("unknown license is idempotent success", async () => {
    const res = await call("/v1/licenses/deactivate", {
      licenseKey: "MOCK-INVALID-0000-0000",
      instanceId: "inst_MOCK_0000000000",
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "deactivated" });
  });

  it("transport error propagates → upstream_unavailable (502)", async () => {
    const res = await call("/v1/licenses/deactivate", {
      licenseKey: "MOCK-5XX-0000-0000",
      instanceId: "inst_MOCK_0000000000",
    });
    expect(res.status).toBe(502);
    expect(await res.json()).toMatchObject({ error: "upstream_unavailable" });
  });
});

describe("input validation & abuse guards", () => {
  beforeEach(async () => resetSchema());

  it("unknown field → invalid_request (400)", async () => {
    const res = await call("/v1/licenses/activate", {
      licenseKey: "MOCK-LICENSE-0000-0000-0000",
      instanceName: "n",
      appVersion: "1.0.0",
      evil: "extra",
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toMatchObject({ error: "invalid_request" });
  });

  it("license key too short → invalid_request (400)", async () => {
    const res = await call("/v1/licenses/activate", {
      licenseKey: "short",
      instanceName: "n",
      appVersion: "1.0.0",
    });
    expect(res.status).toBe(400);
  });

  it("wrong content-type → invalid_request (400)", async () => {
    const req = new Request("https://api.appidge.com/v1/licenses/activate", {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body: "{}",
    });
    const res = await handleRequest(req, ctxWith({ now: fixedClock(CLOCK) }));
    expect(res.status).toBe(400);
    expect(await res.json()).toMatchObject({ error: "invalid_request" });
  });

  it("malformed JSON → invalid_request (400)", async () => {
    const req = new Request("https://api.appidge.com/v1/licenses/activate", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{ not json",
    });
    const res = await handleRequest(req, ctxWith({ now: fixedClock(CLOCK) }));
    expect(res.status).toBe(400);
  });

  it("oversize body → invalid_request (400)", async () => {
    const big = "x".repeat(20000);
    const res = await call("/v1/licenses/activate", {
      licenseKey: "MOCK-LICENSE-0000-0000-0000",
      instanceName: big,
      appVersion: "1.0.0",
    });
    expect(res.status).toBe(400);
  });

  it("streamed oversize body without Content-Length stops reading at the configured limit", async () => {
    let cancelled = false;
    let pulls = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulls += 1;
        if (pulls <= 4) {
          controller.enqueue(new Uint8Array(6000));
        } else {
          controller.close();
        }
      },
      cancel() {
        cancelled = true;
      },
    });
    const req = new Request("https://api.appidge.com/v1/licenses/activate", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: stream,
    });
    const res = await handleRequest(req, ctxWith({ now: fixedClock(CLOCK) }));
    expect(res.status).toBe(400);
    expect(await res.json()).toMatchObject({ error: "invalid_request" });
    expect(cancelled).toBe(true);
    expect(pulls).toBeLessThanOrEqual(3);
  });

  it("rate limit path → rate_limited (429)", async () => {
    const limiter = new FixedWindowRateLimiter(2, 60000);
    const overrides = { now: fixedClock(CLOCK), rateLimiter: limiter };
    const body = { licenseKey: "MOCK-LICENSE-0000-0000-0000", instanceId: "i", appVersion: "1.0.0" };
    const r1 = await handleRequest(jsonPost("/v1/licenses/validate", body), ctxWith(overrides));
    const r2 = await handleRequest(jsonPost("/v1/licenses/validate", body), ctxWith(overrides));
    const r3 = await handleRequest(jsonPost("/v1/licenses/validate", body), ctxWith(overrides));
    expect(r1.status).toBe(200);
    expect(r2.status).toBe(200);
    expect(r3.status).toBe(429);
    expect(await r3.json()).toMatchObject({ error: "rate_limited" });
  });

  it("unknown route → 404", async () => {
    const res = await handleRequest(new Request("https://api.appidge.com/nope"), ctxWith());
    expect(res.status).toBe(404);
  });
});

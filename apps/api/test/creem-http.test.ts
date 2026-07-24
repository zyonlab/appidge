import { describe, expect, it } from "vitest";
import { ApiError } from "../src/errors";
import { normalizeStatus } from "../src/creem/http";

function expectTransient(run: () => unknown): void {
  try {
    run();
    throw new Error("expected normalizeStatus to throw");
  } catch (error) {
    expect(error).toBeInstanceOf(ApiError);
    expect((error as ApiError).code).toBe("upstream_unavailable");
  }
}

describe("Creem HTTP response normalization", () => {
  const now = Date.parse("2026-01-01T00:00:00Z");

  it("maps only explicit active/inactive/expired/disabled statuses", () => {
    expect(normalizeStatus("active", null, now)).toBe("active");
    expect(normalizeStatus("expired", null, now)).toBe("expired");
    // inactive/disabled → facade revoked（2026-07-22 真实 test 全链路验证：
    // Dashboard 手动 disable → validate=disabled → 我们映射 revoked）
    expect(normalizeStatus("disabled", null, now)).toBe("inactive");
    expect(normalizeStatus("inactive", null, now)).toBe("inactive");
  });

  it("treats missing or future statuses as transient upstream failures, never revoked", () => {
    expectTransient(() => normalizeStatus(undefined, null, now));
    expectTransient(() => normalizeStatus("", null, now));
    expectTransient(() => normalizeStatus("paused", null, now));
  });

  it("rejects malformed expiry fields and expires an active status past expires_at", () => {
    expectTransient(() => normalizeStatus("active", "not-a-date", now));
    expect(normalizeStatus("active", "2025-12-31T00:00:00Z", now)).toBe("expired");
    expect(normalizeStatus("active", "2026-06-01T00:00:00Z", now)).toBe("active");
  });
});

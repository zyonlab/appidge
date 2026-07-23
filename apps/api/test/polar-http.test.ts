import { describe, expect, it } from "vitest";
import { ApiError } from "../src/errors";
import { normalizeStatus } from "../src/polar/http";

function expectTransient(run: () => unknown): void {
  try {
    run();
    throw new Error("expected normalizeStatus to throw");
  } catch (error) {
    expect(error).toBeInstanceOf(ApiError);
    expect((error as ApiError).code).toBe("upstream_unavailable");
  }
}

describe("Polar HTTP response normalization", () => {
  const now = Date.parse("2026-01-01T00:00:00Z");

  it("maps only explicit granted/revoked/disabled statuses", () => {
    expect(normalizeStatus("granted", null, now)).toBe("active");
    expect(normalizeStatus("revoked", null, now)).toBe("inactive");
    expect(normalizeStatus("disabled", null, now)).toBe("inactive");
  });

  it("treats missing or future statuses as transient upstream failures, never revoked", () => {
    expectTransient(() => normalizeStatus(undefined, null, now));
    expectTransient(() => normalizeStatus("", null, now));
    expectTransient(() => normalizeStatus("paused", null, now));
  });

  it("rejects malformed expiry fields and only expires a valid explicit status", () => {
    expectTransient(() => normalizeStatus("granted", "not-a-date", now));
    expect(normalizeStatus("granted", "2025-12-31T00:00:00Z", now)).toBe("expired");
  });
});

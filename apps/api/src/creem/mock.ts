// MockCreemClient —— 无网络、确定性。让全套自动测试无需真实 secret 即可跑通。
// 行为由 license key 前缀决定，便于在测试里精确覆盖各分支与 Creem 4xx/5xx/timeout 映射。
//
//   MOCK-LICENSE...      → active，limit 3，activations 1，买断（expiresAt null）
//   MOCK-EXPIRED...      → expired
//   MOCK-DISABLED...     → inactive（validate 时表现为 revoked）
//   MOCK-LIMIT...        → activate 抛 activation_limit
//   MOCK-INVALID...      → invalid_license
//   MOCK-RATELIMIT...    → 上游 429 → rate_limited
//   MOCK-5XX...          → 上游 500 → upstream_unavailable
//   MOCK-TIMEOUT...      → 超时 → upstream_unavailable
import { ApiError } from "../errors";
import type { CreemClient, CreemLicenseResult } from "./client";

const DEFAULT_INSTANCE = "inst_MOCK_0000000000";

function kindOf(key: string): string {
  const up = key.toUpperCase();
  if (up.startsWith("MOCK-EXPIRED")) return "expired";
  if (up.startsWith("MOCK-DISABLED")) return "disabled";
  if (up.startsWith("MOCK-LIMIT")) return "limit";
  if (up.startsWith("MOCK-INVALID")) return "invalid";
  if (up.startsWith("MOCK-RATELIMIT")) return "ratelimit";
  if (up.startsWith("MOCK-5XX")) return "5xx";
  if (up.startsWith("MOCK-TIMEOUT")) return "timeout";
  return "active";
}

function throwForTransport(kind: string): void {
  if (kind === "ratelimit") throw new ApiError("rate_limited");
  if (kind === "5xx") throw new ApiError("upstream_unavailable");
  if (kind === "timeout") throw new ApiError("upstream_unavailable", "Upstream timed out");
}

export class MockCreemClient implements CreemClient {
  async activate(licenseKey: string, _instanceName: string): Promise<CreemLicenseResult> {
    const kind = kindOf(licenseKey);
    throwForTransport(kind);
    if (kind === "invalid") throw new ApiError("invalid_license");
    if (kind === "limit") throw new ApiError("activation_limit");
    if (kind === "expired") throw new ApiError("expired");
    return {
      status: "active",
      instanceId: DEFAULT_INSTANCE,
      expiresAt: null,
      activations: 1,
      activationLimit: 3,
    };
  }

  async validate(licenseKey: string, instanceId: string): Promise<CreemLicenseResult> {
    const kind = kindOf(licenseKey);
    throwForTransport(kind);
    if (kind === "invalid") return { status: "inactive", instanceId, expiresAt: null, activations: 0, activationLimit: 3 };
    if (kind === "disabled") return { status: "inactive", instanceId, expiresAt: null, activations: 1, activationLimit: 3 };
    if (kind === "expired") return { status: "expired", instanceId, expiresAt: "2020-01-01T00:00:00Z", activations: 1, activationLimit: 3 };
    return { status: "active", instanceId, expiresAt: null, activations: 1, activationLimit: 3 };
  }

  async deactivate(licenseKey: string, _instanceId: string): Promise<void> {
    const kind = kindOf(licenseKey);
    throwForTransport(kind);
    // invalid/未知实例：幂等成功（handler 决定），mock 不抛。
  }
}

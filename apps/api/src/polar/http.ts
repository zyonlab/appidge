// HttpPolarClient —— 真实 Polar license-key API（sandbox 或生产 base）。
// 仅在 MOCK_MODE=false 且注入了真实 POLAR_ACCESS_TOKEN 时使用；自动测试永不走这里。
// Bearer token 只从 env binding 取，绝不进日志/响应。
//
// 组织级端点（access token 鉴权，body 必带 organization_id）：
//   POST /v1/license-keys/activate    { key, organization_id, label }        → LicenseKeyActivationRead
//   POST /v1/license-keys/validate    { key, organization_id, activation_id? } → LicenseKeyRead(+activation)
//   POST /v1/license-keys/deactivate  { key, organization_id, activation_id }  → 204
import { ApiError } from "../errors";
import type { LicenseClient, UpstreamLicenseResult } from "./client";

const TIMEOUT_MS = 8000;

// Polar LicenseKeyStatus：granted | revoked | disabled。
// 只有明确 revoked/disabled 才能形成不可逆的本地吊销；缺失/未知状态属于上游契约漂移，
// 必须按 transient failure 进入客户端宽限，绝不能误翻成 revoked。
export function normalizeStatus(
  rawStatus: unknown,
  expiresAt: string | null,
  nowMs: number,
): UpstreamLicenseResult["status"] {
  if (typeof rawStatus !== "string") {
    throw new ApiError("upstream_unavailable", "Malformed upstream response");
  }
  const s = rawStatus.toLowerCase();
  if (s !== "granted" && s !== "revoked" && s !== "disabled") {
    throw new ApiError("upstream_unavailable", "Unknown upstream license status");
  }
  if (expiresAt !== null) {
    const t = Date.parse(expiresAt);
    if (!Number.isFinite(t)) {
      throw new ApiError("upstream_unavailable", "Malformed upstream response");
    }
    if (t <= nowMs) return "expired";
  }
  if (s === "granted") return "active";
  return "inactive"; // 仅明确 revoked / disabled
}

// Polar LicenseKeyRead（validate 直接返回；activate 嵌在 .license_key）。
interface PolarLicenseKey {
  id?: string;
  status?: string;
  expires_at?: string | null;
  limit_activations?: number | null;
  usage?: number;
  activation?: { id?: string } | null;
}
// Polar LicenseKeyActivationRead（activate 返回）。
interface PolarActivation {
  id?: string; // activation id
  license_key_id?: string;
  license_key?: PolarLicenseKey;
}

export class HttpPolarClient implements LicenseClient {
  constructor(
    private readonly base: string,
    private readonly token: string,
    private readonly organizationId: string,
    private readonly now: () => Date = () => new Date(),
  ) {}

  private async call(path: string, body: Record<string, unknown>): Promise<unknown> {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
    let res: Response;
    try {
      res = await fetch(`${this.base}${path}`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${this.token}`,
        },
        body: JSON.stringify(body),
        signal: ctrl.signal,
      });
    } catch {
      // 网络错误 / 超时 —— 绝不透传底层异常文本
      throw new ApiError("upstream_unavailable");
    } finally {
      clearTimeout(timer);
    }

    if (res.status === 429) throw new ApiError("rate_limited");
    if (res.status >= 500) throw new ApiError("upstream_unavailable");
    if (res.status === 404) throw new ApiError("invalid_license");
    if (res.status >= 400) {
      // 4xx：读取上游 detail/error 做最小翻译，但绝不把上游文本塞进 message。
      let hint = "";
      try {
        const j = (await res.json()) as { detail?: unknown; error?: string };
        const d = typeof j.detail === "string" ? j.detail : Array.isArray(j.detail) ? JSON.stringify(j.detail) : "";
        hint = `${d} ${j.error ?? ""}`.toLowerCase();
      } catch {
        /* ignore */
      }
      if (hint.includes("limit")) throw new ApiError("activation_limit");
      if (hint.includes("expired") || hint.includes("expire")) throw new ApiError("expired");
      throw new ApiError("invalid_license");
    }

    if (res.status === 204) return {};
    try {
      return await res.json();
    } catch {
      throw new ApiError("upstream_unavailable", "Malformed upstream response");
    }
  }

  private lkToResult(lk: PolarLicenseKey, fallbackInstance: string): UpstreamLicenseResult {
    const expiresAt = lk.expires_at ?? null;
    if (typeof lk.id !== "string" || lk.id.length === 0) {
      throw new ApiError("upstream_unavailable", "Malformed upstream response");
    }
    return {
      status: normalizeStatus(lk.status, expiresAt, this.now().getTime()),
      instanceId: lk.activation?.id ?? fallbackInstance,
      licenseKeyId: lk.id,
      expiresAt,
      activations: typeof lk.usage === "number" ? lk.usage : 0,
      activationLimit: lk.limit_activations === undefined ? null : lk.limit_activations,
    };
  }

  async activate(licenseKey: string, instanceName: string): Promise<UpstreamLicenseResult> {
    const raw = await this.call("/v1/license-keys/activate", {
      key: licenseKey,
      organization_id: this.organizationId,
      label: instanceName,
    });
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      throw new ApiError("upstream_unavailable", "Malformed upstream response");
    }
    const j = raw as PolarActivation;
    if (typeof j.license_key !== "object" || j.license_key === null || Array.isArray(j.license_key)) {
      throw new ApiError("upstream_unavailable", "Malformed upstream response");
    }
    const lk = j.license_key;
    const result = this.lkToResult(lk, j.id ?? "");
    // activate 的 activation id 在顶层 .id；license_key_id 在顶层或 lk.id。
    result.instanceId = j.id ?? result.instanceId;
    result.licenseKeyId = j.license_key_id ?? lk.id ?? result.licenseKeyId;
    return result;
  }

  async validate(licenseKey: string, instanceId: string): Promise<UpstreamLicenseResult> {
    const raw = await this.call("/v1/license-keys/validate", {
      key: licenseKey,
      organization_id: this.organizationId,
      activation_id: instanceId,
    });
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      throw new ApiError("upstream_unavailable", "Malformed upstream response");
    }
    return this.lkToResult(raw as PolarLicenseKey, instanceId);
  }

  async deactivate(licenseKey: string, instanceId: string): Promise<void> {
    await this.call("/v1/license-keys/deactivate", {
      key: licenseKey,
      organization_id: this.organizationId,
      activation_id: instanceId,
    });
  }
}

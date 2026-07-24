// HttpCreemClient —— 真实 Creem license API（test 或生产 base）。
// 仅在 MOCK_MODE=false 且注入了真实 CREEM_API_KEY 时使用；自动测试永不走这里。
// x-api-key 只从 env binding 取，绝不进日志/响应。
//
// 端点（官方文档 docs.creem.io/api-reference/endpoint/{activate,validate,deactivate}-license，
// 2026-07 复核；base：生产 https://api.creem.io，test https://test-api.creem.io）：
//   POST /v1/licenses/activate    { key, instance_name }  → LicenseEntity（含 instance）
//   POST /v1/licenses/validate    { key, instance_id }    → LicenseEntity
//   POST /v1/licenses/deactivate  { key, instance_id }    → LicenseEntity
import { ApiError } from "../errors";
import type { LicenseClient, UpstreamLicenseResult } from "./client";

const TIMEOUT_MS = 8000;

// Creem LicenseEntity.status：inactive | active | expired | disabled。
// 只有明确 inactive/disabled 才能形成 facade revoked（2026-07-22 真实 test 全链路验证：
// Dashboard 手动 disable → validate=disabled）；缺失/未知状态属于上游契约漂移，
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
  if (s !== "active" && s !== "inactive" && s !== "expired" && s !== "disabled") {
    throw new ApiError("upstream_unavailable", "Unknown upstream license status");
  }
  if (expiresAt !== null) {
    const t = Date.parse(expiresAt);
    if (!Number.isFinite(t)) {
      throw new ApiError("upstream_unavailable", "Malformed upstream response");
    }
    if (t <= nowMs) return "expired";
  }
  if (s === "active") return "active";
  if (s === "expired") return "expired";
  return "inactive"; // 仅明确 inactive / disabled
}

// Creem LicenseInstanceEntity（instance 字段；官方 schema 为对象，容错数组取首个）。
interface CreemInstance {
  id?: string;
}
// Creem LicenseEntity（activate/validate/deactivate 都返回本形态）。
interface CreemLicense {
  id?: string; // license 对象 id —— 我们的本地 join key
  status?: string;
  expires_at?: string | null;
  activation?: number;
  activation_limit?: number | null;
  instance?: CreemInstance | CreemInstance[] | null;
}

function instanceIdOf(v: CreemLicense["instance"]): string | undefined {
  if (Array.isArray(v)) return v[0]?.id;
  return v?.id ?? undefined;
}

export class HttpCreemClient implements LicenseClient {
  constructor(
    private readonly base: string,
    private readonly apiKey: string,
    private readonly now: () => Date = () => new Date(),
  ) {}

  private async call(path: string, body: Record<string, unknown>): Promise<CreemLicense> {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
    let res: Response;
    try {
      res = await fetch(`${this.base}${path}`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-api-key": this.apiKey,
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
      // 4xx：读取上游 code/error/message 做最小翻译，但绝不把上游文本塞进 message。
      let hint = "";
      try {
        const j = (await res.json()) as { code?: unknown; error?: unknown; message?: unknown };
        hint = [j.code, j.error, j.message]
          .map((v) => (typeof v === "string" ? v : Array.isArray(v) ? v.join(" ") : ""))
          .join(" ")
          .toLowerCase();
      } catch {
        /* ignore */
      }
      if (hint.includes("limit")) throw new ApiError("activation_limit");
      if (hint.includes("expire")) throw new ApiError("expired");
      throw new ApiError("invalid_license");
    }

    try {
      return (await res.json()) as CreemLicense;
    } catch {
      throw new ApiError("upstream_unavailable", "Malformed upstream response");
    }
  }

  private toResult(j: CreemLicense, fallbackInstance: string): UpstreamLicenseResult {
    if (typeof j !== "object" || j === null || Array.isArray(j)) {
      throw new ApiError("upstream_unavailable", "Malformed upstream response");
    }
    if (typeof j.id !== "string" || j.id.length === 0) {
      throw new ApiError("upstream_unavailable", "Malformed upstream response");
    }
    const expiresAt = j.expires_at ?? null;
    return {
      status: normalizeStatus(j.status, expiresAt, this.now().getTime()),
      instanceId: instanceIdOf(j.instance) ?? fallbackInstance,
      licenseKeyId: j.id,
      expiresAt,
      activations: typeof j.activation === "number" ? j.activation : 0,
      activationLimit: j.activation_limit === undefined ? null : j.activation_limit,
    };
  }

  async activate(licenseKey: string, instanceName: string): Promise<UpstreamLicenseResult> {
    const j = await this.call("/v1/licenses/activate", { key: licenseKey, instance_name: instanceName });
    return this.toResult(j, "");
  }

  async validate(licenseKey: string, instanceId: string): Promise<UpstreamLicenseResult> {
    const j = await this.call("/v1/licenses/validate", { key: licenseKey, instance_id: instanceId });
    return this.toResult(j, instanceId);
  }

  async deactivate(licenseKey: string, instanceId: string): Promise<void> {
    await this.call("/v1/licenses/deactivate", { key: licenseKey, instance_id: instanceId });
  }
}

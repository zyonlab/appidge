// HttpCreemClient —— 真实 Creem license API（test 或生产 base）。
// 仅在 MOCK_MODE=false 且注入了真实 CREEM_API_KEY 时使用；自动测试永不走这里。
// x-api-key 只从 env binding 取，绝不进日志/响应。
import { ApiError } from "../errors";
import type { CreemClient, CreemLicenseResult } from "./client";

const TIMEOUT_MS = 8000;

// Creem 原始 status → facade 中间态。文档：active/inactive/expired/disabled。
function normalizeStatus(raw: unknown): CreemLicenseResult["status"] {
  const s = String(raw ?? "").toLowerCase();
  if (s === "active") return "active";
  if (s === "expired") return "expired";
  return "inactive"; // inactive / disabled / 未知 → 保守视为 inactive（facade → revoked）
}

interface CreemInstance {
  id?: string;
}
interface CreemLicenseResponse {
  status?: string;
  expires_at?: string | null;
  activation?: number;
  activation_limit?: number | null;
  instance?: CreemInstance;
}

export class HttpCreemClient implements CreemClient {
  constructor(
    private readonly base: string,
    private readonly apiKey: string,
  ) {}

  private async call(path: string, body: Record<string, unknown>): Promise<CreemLicenseResponse> {
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
      // 4xx：读取上游 code 做最小翻译，但绝不把上游文本塞进 message
      let code = "";
      try {
        const j = (await res.json()) as { code?: string; error?: string };
        code = String(j.code ?? j.error ?? "").toLowerCase();
      } catch {
        /* ignore */
      }
      if (code.includes("limit")) throw new ApiError("activation_limit");
      if (code.includes("expired")) throw new ApiError("expired");
      throw new ApiError("invalid_license");
    }

    try {
      return (await res.json()) as CreemLicenseResponse;
    } catch {
      throw new ApiError("upstream_unavailable", "Malformed upstream response");
    }
  }

  private toResult(j: CreemLicenseResponse, fallbackInstance: string): CreemLicenseResult {
    return {
      status: normalizeStatus(j.status),
      instanceId: j.instance?.id ?? fallbackInstance,
      expiresAt: j.expires_at ?? null,
      activations: typeof j.activation === "number" ? j.activation : 0,
      activationLimit: j.activation_limit === undefined ? null : j.activation_limit,
    };
  }

  async activate(licenseKey: string, instanceName: string): Promise<CreemLicenseResult> {
    const j = await this.call("/v1/licenses/activate", { key: licenseKey, instance_name: instanceName });
    return this.toResult(j, "");
  }

  async validate(licenseKey: string, instanceId: string): Promise<CreemLicenseResult> {
    const j = await this.call("/v1/licenses/validate", { key: licenseKey, instance_id: instanceId });
    return this.toResult(j, instanceId);
  }

  async deactivate(licenseKey: string, instanceId: string): Promise<void> {
    await this.call("/v1/licenses/deactivate", { key: licenseKey, instance_id: instanceId });
  }
}

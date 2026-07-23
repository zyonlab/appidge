// Polar license 客户端协议边界。两个实现：MockPolarClient（无网络、确定性）与
// HttpPolarClient（真实 sandbox/prod API）。上层 handler 只依赖本接口，MOCK_MODE 决定注入哪个。
import { ApiError } from "../errors";

// 稳定化后的 license 结果（已从 Polar 原始枚举翻译）。
export interface UpstreamLicenseResult {
  status: "active" | "expired" | "inactive"; // inactive 泛指 revoked/disabled → facade 映射为 revoked
  instanceId: string; // Polar activation id（app 后续 validate/deactivate 必用）
  licenseKeyId: string; // Polar license key id —— webhook 与 app 路径共享的稳定 join key
  expiresAt: string | null;
  activations: number; // Polar usage
  activationLimit: number | null; // Polar limit_activations
}

export interface LicenseClient {
  activate(licenseKey: string, instanceName: string): Promise<UpstreamLicenseResult>;
  validate(licenseKey: string, instanceId: string): Promise<UpstreamLicenseResult>;
  deactivate(licenseKey: string, instanceId: string): Promise<void>;
}

// 把上游 HTTP 状态统一翻译成 facade ApiError。绝不透传上游文本。
export function mapUpstreamStatusToError(httpStatus: number): ApiError {
  if (httpStatus === 429) return new ApiError("rate_limited");
  if (httpStatus >= 500) return new ApiError("upstream_unavailable");
  if (httpStatus === 404) return new ApiError("invalid_license");
  return new ApiError("upstream_unavailable");
}

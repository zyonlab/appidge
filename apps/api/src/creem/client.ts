// Creem license 客户端协议边界。两个实现：MockCreemClient（无网络、确定性）与
// HttpCreemClient（真实 test/prod API）。上层 handler 只依赖本接口，MOCK_MODE 决定注入哪个。
import { ApiError } from "../errors";

// 稳定化后的 license 结果（已从 Creem 原始枚举翻译）。
export interface UpstreamLicenseResult {
  status: "active" | "expired" | "inactive"; // inactive 泛指 Creem inactive/disabled → facade 映射为 revoked
  instanceId: string; // Creem license instance id（app 后续 validate/deactivate 必用）
  licenseKeyId: string; // Creem license 对象 id（响应顶层 id）—— app 路径的本地 join key。
  // ⚠️ 与 Polar 不同：Creem webhook 不携带任何 license 标识（订单中心 payload），
  // 该 id 只在 app 路径（activate/validate 响应）可得，webhook 无法用它精确吊销。
  expiresAt: string | null;
  activations: number; // Creem activation（当前已激活实例数）
  activationLimit: number | null; // Creem activation_limit（null=无限）
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

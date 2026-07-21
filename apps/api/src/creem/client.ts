// Creem license 客户端协议边界。两个实现：MockCreemClient（无网络、确定性）与
// HttpCreemClient（真实 test API）。上层 handler 只依赖本接口，MOCK_MODE 决定注入哪个。
import { ApiError } from "../errors";

// 稳定化后的 license 结果（已从 Creem 原始枚举翻译）。
export interface CreemLicenseResult {
  status: "active" | "expired" | "inactive"; // inactive 泛指 disabled/inactive → facade 映射为 revoked
  instanceId: string;
  expiresAt: string | null;
  activations: number;
  activationLimit: number | null;
}

export interface CreemClient {
  activate(licenseKey: string, instanceName: string): Promise<CreemLicenseResult>;
  validate(licenseKey: string, instanceId: string): Promise<CreemLicenseResult>;
  deactivate(licenseKey: string, instanceId: string): Promise<void>;
}

// 把 Creem 上游的 HTTP/异常统一翻译成 facade ApiError。绝不透传上游文本。
export function mapUpstreamStatusToError(httpStatus: number): ApiError {
  if (httpStatus === 429) return new ApiError("rate_limited");
  if (httpStatus >= 500) return new ApiError("upstream_unavailable");
  // 4xx（非 429）在具体 handler 里已按业务翻译；到这里的算通用无效请求
  if (httpStatus === 404) return new ApiError("invalid_license");
  return new ApiError("upstream_unavailable");
}

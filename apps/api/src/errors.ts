// 稳定错误模型 —— 与 contracts/licensing.openapi.yaml 的 Error.enum 完全一致。
// 绝不透传 Creem 内部响应文本；message 只放脱敏的人类可读补充。

export type ErrorCode =
  | "invalid_request"
  | "invalid_license"
  | "activation_limit"
  | "expired"
  | "revoked"
  | "rate_limited"
  | "upstream_unavailable"
  | "internal_error";

// 错误码 → HTTP 状态。契约每条路由声明的状态集合是这些的子集。
const HTTP_STATUS: Record<ErrorCode, number> = {
  invalid_request: 400,
  invalid_license: 402,
  activation_limit: 409,
  expired: 402,
  revoked: 403,
  rate_limited: 429,
  upstream_unavailable: 502,
  internal_error: 500,
};

export class ApiError extends Error {
  readonly code: ErrorCode;
  readonly httpStatus: number;
  readonly publicMessage?: string;

  constructor(code: ErrorCode, publicMessage?: string, httpStatusOverride?: number) {
    super(publicMessage ?? code);
    this.name = "ApiError";
    this.code = code;
    this.httpStatus = httpStatusOverride ?? HTTP_STATUS[code];
    this.publicMessage = publicMessage;
  }
}

export function httpStatusFor(code: ErrorCode): number {
  return HTTP_STATUS[code];
}

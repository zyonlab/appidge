// 统一 JSON 响应 + 错误体（对齐 openapi Error schema）。
import { ApiError, type ErrorCode } from "./errors";

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" };

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

export function errorResponse(code: ErrorCode, httpStatus: number, message?: string): Response {
  const body: { error: ErrorCode; message?: string } = { error: code };
  if (message) body.message = message;
  return json(body, httpStatus);
}

export function fromApiError(err: ApiError): Response {
  return errorResponse(err.code, err.httpStatus, err.publicMessage);
}

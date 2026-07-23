// 输入校验：body 大小、Content-Type、字段白名单/长度、product ID 白名单。
// 严格对齐 licensing.openapi.yaml 的 request schema（additionalProperties:false + 长度约束）。
// 本 Worker 不是通用 Polar 代理，一切请求都必须显式白名单通过。

import { ApiError } from "./errors";

export interface RawRequest {
  bytes: ArrayBuffer;
  text: string;
}

// 读取并限制 body 大小；强制 application/json。返回原始字节（webhook 验签需要）。
export async function readJsonBody(req: Request, maxBytes: number): Promise<RawRequest> {
  const ct = req.headers.get("content-type") ?? "";
  if (!/^application\/json\b/i.test(ct)) {
    throw new ApiError("invalid_request", "Content-Type must be application/json");
  }
  const declaredLength = req.headers.get("content-length");
  if (declaredLength !== null) {
    const parsed = Number.parseInt(declaredLength, 10);
    if (Number.isFinite(parsed) && parsed > maxBytes) {
      throw new ApiError("invalid_request", "Request body too large");
    }
  }

  const reader = req.body?.getReader();
  if (!reader) {
    const bytes = new ArrayBuffer(0);
    return { bytes, text: "" };
  }

  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      try {
        await reader.cancel("request body too large");
      } catch {
        // cancel 是尽力而为；无论底层是否接受取消，都立即停止继续读取。
      }
      throw new ApiError("invalid_request", "Request body too large");
    }
    chunks.push(value);
  }

  const combined = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    combined.set(chunk, offset);
    offset += chunk.byteLength;
  }
  const bytes = combined.buffer;
  if (bytes.byteLength > maxBytes) {
    throw new ApiError("invalid_request", "Request body too large");
  }
  const text = new TextDecoder().decode(bytes);
  return { bytes, text };
}

export function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    throw new ApiError("invalid_request", "Malformed JSON body");
  }
}

type FieldSpec = { min?: number; max?: number };

function assertObject(v: unknown): Record<string, unknown> {
  if (typeof v !== "object" || v === null || Array.isArray(v)) {
    throw new ApiError("invalid_request", "Body must be a JSON object");
  }
  return v as Record<string, unknown>;
}

function assertString(obj: Record<string, unknown>, key: string, spec: FieldSpec): string {
  const val = obj[key];
  if (typeof val !== "string") {
    throw new ApiError("invalid_request", `Field '${key}' must be a string`);
  }
  if (spec.min !== undefined && val.length < spec.min) {
    throw new ApiError("invalid_request", `Field '${key}' too short`);
  }
  if (spec.max !== undefined && val.length > spec.max) {
    throw new ApiError("invalid_request", `Field '${key}' too long`);
  }
  return val;
}

// additionalProperties:false —— 拒绝任何未知字段。
function rejectUnknown(obj: Record<string, unknown>, allowed: string[]): void {
  for (const k of Object.keys(obj)) {
    if (!allowed.includes(k)) {
      throw new ApiError("invalid_request", `Unknown field '${k}'`);
    }
  }
}

export interface ActivateInput {
  licenseKey: string;
  instanceName: string;
  appVersion: string;
}
export function parseActivate(v: unknown): ActivateInput {
  const o = assertObject(v);
  rejectUnknown(o, ["licenseKey", "instanceName", "appVersion"]);
  return {
    licenseKey: assertString(o, "licenseKey", { min: 8, max: 200 }),
    instanceName: assertString(o, "instanceName", { min: 1, max: 120 }),
    appVersion: assertString(o, "appVersion", { max: 40 }),
  };
}

export interface ValidateInput {
  licenseKey: string;
  instanceId: string;
  appVersion: string;
}
export function parseValidate(v: unknown): ValidateInput {
  const o = assertObject(v);
  rejectUnknown(o, ["licenseKey", "instanceId", "appVersion"]);
  return {
    licenseKey: assertString(o, "licenseKey", { min: 8, max: 200 }),
    instanceId: assertString(o, "instanceId", { min: 1, max: 120 }),
    appVersion: assertString(o, "appVersion", { max: 40 }),
  };
}

export interface DeactivateInput {
  licenseKey: string;
  instanceId: string;
}
export function parseDeactivate(v: unknown): DeactivateInput {
  const o = assertObject(v);
  rejectUnknown(o, ["licenseKey", "instanceId"]);
  return {
    licenseKey: assertString(o, "licenseKey", { min: 8, max: 200 }),
    instanceId: assertString(o, "instanceId", { min: 1, max: 120 }),
  };
}

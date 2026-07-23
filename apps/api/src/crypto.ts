// 加密工具：Polar webhook 验签（Standard Webhooks）、恒定时间比较、license 指纹。
// 全部走 WebCrypto（Workers runtime 原生）。

const enc = new TextEncoder();

async function hmacSha256(secret: ArrayBuffer | Uint8Array, message: ArrayBuffer | Uint8Array): Promise<Uint8Array> {
  const keyData = secret instanceof Uint8Array ? secret : new Uint8Array(secret);
  const key = await crypto.subtle.importKey("raw", keyData, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const data = message instanceof Uint8Array ? message : new Uint8Array(message);
  const sig = await crypto.subtle.sign("HMAC", key, data);
  return new Uint8Array(sig);
}

function toHex(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

function bytesToBase64(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// 恒定时间比较两个字符串（长度不同也走满全程，避免早退时序泄漏）。
export function timingSafeEqual(a: string, b: string): boolean {
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  const len = Math.max(ab.length, bb.length);
  let diff = ab.length ^ bb.length;
  for (let i = 0; i < len; i++) {
    diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  }
  return diff === 0;
}

// Standard Webhooks 密钥可能带 `whsec_` 前缀，其余部分为 base64。解出原始字节。
function decodeWebhookSecret(secret: string): Uint8Array {
  const raw = secret.startsWith("whsec_") ? secret.slice("whsec_".length) : secret;
  try {
    return base64ToBytes(raw);
  } catch {
    // 非 base64 → 退化为原始 UTF-8 字节（容错，不抛）
    return enc.encode(raw);
  }
}

export interface WebhookHeaders {
  id: string | null; // webhook-id
  timestamp: string | null; // webhook-timestamp（Unix 秒）
  signature: string | null; // webhook-signature（空格分隔的 v1,<base64> 列表）
}

// 允许的时间戳漂移（防重放）。默认 ±5 分钟。
const DEFAULT_TOLERANCE_S = 300;

// Standard Webhooks 验签：
//   signedContent = `${id}.${timestamp}.${rawBody}`
//   expected = base64(HMAC-SHA256(secretBytes, signedContent))
//   webhook-signature 头为空格分隔的多个 `v1,<base64sig>`，任一匹配即通过。
// 同时校验时间戳漂移，超窗直接拒绝。
export async function verifyStandardWebhook(
  secret: string,
  rawBody: ArrayBuffer,
  headers: WebhookHeaders,
  opts?: { nowMs?: number; toleranceS?: number },
): Promise<boolean> {
  const { id, timestamp, signature } = headers;
  if (!id || !timestamp || !signature) return false;

  const ts = Number.parseInt(timestamp, 10);
  if (!Number.isFinite(ts)) return false;
  const nowS = Math.floor((opts?.nowMs ?? Date.now()) / 1000);
  const tolerance = opts?.toleranceS ?? DEFAULT_TOLERANCE_S;
  if (Math.abs(nowS - ts) > tolerance) return false;

  const bodyStr = new TextDecoder().decode(rawBody);
  const signedContent = enc.encode(`${id}.${timestamp}.${bodyStr}`);
  const secretBytes = decodeWebhookSecret(secret);
  const expected = bytesToBase64(await hmacSha256(secretBytes, signedContent));

  const candidates = signature
    .split(" ")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((tok) => (tok.startsWith("v1,") ? tok.slice(3) : tok.includes(",") ? tok.slice(tok.indexOf(",") + 1) : tok));

  let ok = false;
  for (const c of candidates) {
    // 全程比较所有候选，避免早退
    ok = timingSafeEqual(expected, c) || ok;
  }
  return ok;
}

// 供测试/工具生成 Standard Webhooks 签名头值（`v1,<base64>`）。
export async function signStandardWebhook(
  secret: string,
  id: string,
  timestamp: string,
  rawBody: ArrayBuffer | Uint8Array,
): Promise<string> {
  const bodyStr = new TextDecoder().decode(rawBody instanceof Uint8Array ? rawBody : new Uint8Array(rawBody));
  const signedContent = enc.encode(`${id}.${timestamp}.${bodyStr}`);
  const sig = bytesToBase64(await hmacSha256(decodeWebhookSecret(secret), signedContent));
  return `v1,${sig}`;
}

// license 指纹：HMAC-SHA256(pepper, licenseKey) 的 hex。存 D1，绝不存明文 key。
export async function licenseFingerprint(pepper: string, licenseKey: string): Promise<string> {
  return toHex(await hmacSha256(enc.encode(pepper), enc.encode(licenseKey)));
}

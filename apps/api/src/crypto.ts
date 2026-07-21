// 加密工具：webhook HMAC 验签（over raw bytes）、恒定时间比较、license 指纹。
// 全部走 WebCrypto（Workers runtime 原生）。

const enc = new TextEncoder();

async function hmacSha256(secret: string, message: ArrayBuffer | Uint8Array): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const data = message instanceof Uint8Array ? message : new Uint8Array(message);
  const sig = await crypto.subtle.sign("HMAC", key, data);
  return new Uint8Array(sig);
}

function toHex(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

// 恒定时间比较两个 hex 字符串（长度不同也走满全程，避免早退时序泄漏）。
export function timingSafeEqualHex(a: string, b: string): boolean {
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  const len = Math.max(ab.length, bb.length);
  let diff = ab.length ^ bb.length;
  for (let i = 0; i < len; i++) {
    diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  }
  return diff === 0;
}

// 用收到的原始请求字节计算 HMAC-SHA256，与 creem-signature 头做恒定时间比较。
// signatureHeader 可能是纯 hex，也可能含前缀/多值——这里做最小规整（取 hex 段）。
export async function verifyWebhookSignature(
  secret: string,
  rawBody: ArrayBuffer,
  signatureHeader: string | null,
): Promise<boolean> {
  if (!signatureHeader) return false;
  const expected = toHex(await hmacSha256(secret, rawBody));
  // 允许 "sha256=<hex>" 或多签名逗号分隔；任一匹配即通过。
  const candidates = signatureHeader
    .split(",")
    .map((s) => s.trim())
    .map((s) => (s.includes("=") ? s.slice(s.indexOf("=") + 1) : s))
    .filter(Boolean);
  if (candidates.length === 0) return timingSafeEqualHex(expected, signatureHeader.trim());
  let ok = false;
  for (const c of candidates) {
    // 全程比较所有候选，避免早退
    ok = timingSafeEqualHex(expected, c) || ok;
  }
  return ok;
}

// 供测试/工具生成签名（等价于 Creem 端签名逻辑）。
export async function signWebhook(secret: string, rawBody: ArrayBuffer | Uint8Array): Promise<string> {
  return toHex(await hmacSha256(secret, rawBody));
}

// license 指纹：HMAC-SHA256(pepper, licenseKey) 的 hex。存 D1，绝不存明文 key。
export async function licenseFingerprint(pepper: string, licenseKey: string): Promise<string> {
  return toHex(await hmacSha256(pepper, enc.encode(licenseKey)));
}

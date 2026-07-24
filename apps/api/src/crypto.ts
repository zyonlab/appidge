// 加密工具：Creem webhook 验签（HMAC-SHA256 hex over raw body）、恒定时间比较、license 指纹。
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

// Creem webhook 验签（官方 docs.creem.io/code/webhooks，2026-07 复核）：
//   expected = hex(HMAC-SHA256(secret, rawBody))，与 `creem-signature` 头恒定时间比较。
//   ⚠️ 与 Standard Webhooks（Polar）不同：
//     - secret 按 Dashboard 显示的字面值使用（官方示例 createHmac('sha256', secret) 直接
//       传字符串，whsec_ 前缀不剥离、不做 base64 解码）。
//     - 没有 webhook-id/webhook-timestamp 头，签名不含时间戳 → 无漂移窗口可校验；
//       重放防御依赖 payload 顶层事件 ID 的幂等登记（handlers/webhook.ts）。
export async function verifyCreemWebhook(
  secret: string,
  rawBody: ArrayBuffer,
  signatureHeader: string | null,
): Promise<boolean> {
  if (!secret || !signatureHeader) return false;
  const expected = toHex(await hmacSha256(enc.encode(secret), new Uint8Array(rawBody)));
  // hex 大小写不敏感比较（我们生成小写；对方若给大写也接受）。
  return timingSafeEqual(expected, signatureHeader.trim().toLowerCase());
}

// 供测试/工具生成 creem-signature 头值（hex）。
export async function signCreemWebhook(secret: string, rawBody: ArrayBuffer | Uint8Array): Promise<string> {
  const data = rawBody instanceof Uint8Array ? rawBody : new Uint8Array(rawBody);
  return toHex(await hmacSha256(enc.encode(secret), data));
}

// license 指纹：HMAC-SHA256(pepper, licenseKey) 的 hex。存 D1，绝不存明文 key。
export async function licenseFingerprint(pepper: string, licenseKey: string): Promise<string> {
  return toHex(await hmacSha256(enc.encode(pepper), enc.encode(licenseKey)));
}

// license facade handlers：activate / validate / deactivate。
// 把 Creem 中间态翻译成契约 LicenseState；本地 revoked 优先于上游 active。
import type { AppContext } from "../context";
import { ApiError } from "../errors";
import type { CreemLicenseResult } from "../creem/client";
import { json } from "../responses";
import { parseActivate, parseValidate, parseDeactivate } from "../validation";
import { licenseFingerprint } from "../crypto";
import { isLocallyRevoked } from "../db";

export type LicenseStatus = "active" | "expired" | "revoked";

export interface LicenseState {
  status: LicenseStatus;
  instanceId: string;
  expiresAt: string | null;
  activations: number;
  activationLimit: number | null;
  validatedAt: string;
}

// ISO 无毫秒（对齐契约/fixture 的 date-time 形态）。
function isoNoMillis(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}
function normalizeIso(s: string | null): string | null {
  if (!s) return null;
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? s : isoNoMillis(d);
}

function statusFromCreem(r: CreemLicenseResult): LicenseStatus {
  if (r.status === "active") return "active";
  if (r.status === "expired") return "expired";
  return "revoked"; // inactive / disabled
}

function toState(r: CreemLicenseResult, status: LicenseStatus, validatedAt: string): LicenseState {
  return {
    status,
    instanceId: r.instanceId,
    expiresAt: normalizeIso(r.expiresAt),
    activations: r.activations,
    activationLimit: r.activationLimit,
    validatedAt,
  };
}

export async function handleActivate(ctx: AppContext, body: unknown): Promise<Response> {
  const input = parseActivate(body);
  const result = await ctx.creem.activate(input.licenseKey, input.instanceName);
  const validatedAt = isoNoMillis(ctx.now());
  const status = statusFromCreem(result);
  ctx.logger.info("license.activate", {
    fingerprint: await licenseFingerprint(ctx.env.LICENSE_HMAC_PEPPER, input.licenseKey),
    status,
    instanceId: result.instanceId,
  });
  return json(toState(result, status, validatedAt), 200);
}

export async function handleValidate(ctx: AppContext, body: unknown): Promise<Response> {
  const input = parseValidate(body);
  const fingerprint = await licenseFingerprint(ctx.env.LICENSE_HMAC_PEPPER, input.licenseKey);
  const validatedAt = isoNoMillis(ctx.now());

  // 先查本地 revoked（退款/拒付）——本地 deny 优先于上游 active。
  if (await isLocallyRevoked(ctx.env.DB, fingerprint)) {
    ctx.logger.info("license.validate.local_revoked", { fingerprint, instanceId: input.instanceId });
    return json(
      {
        status: "revoked" satisfies LicenseStatus,
        instanceId: input.instanceId,
        expiresAt: null,
        activations: 0,
        activationLimit: null,
        validatedAt,
      } satisfies LicenseState,
      200,
    );
  }

  const result = await ctx.creem.validate(input.licenseKey, input.instanceId);
  const status = statusFromCreem(result);
  ctx.logger.info("license.validate", { fingerprint, status, instanceId: input.instanceId });
  return json(toState(result, status, validatedAt), 200);
}

export async function handleDeactivate(ctx: AppContext, body: unknown): Promise<Response> {
  const input = parseDeactivate(body);
  try {
    await ctx.creem.deactivate(input.licenseKey, input.instanceId);
  } catch (err) {
    // 传输类错误（429/5xx/timeout）如实映射；license/实例不存在视为幂等成功。
    if (err instanceof ApiError && (err.code === "rate_limited" || err.code === "upstream_unavailable")) {
      throw err;
    }
    // invalid_license 等 → 幂等成功
  }
  ctx.logger.info("license.deactivate", {
    fingerprint: await licenseFingerprint(ctx.env.LICENSE_HMAC_PEPPER, input.licenseKey),
    instanceId: input.instanceId,
  });
  return json({ status: "deactivated" }, 200);
}

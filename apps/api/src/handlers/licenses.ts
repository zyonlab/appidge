// license facade handlers：activate / validate / deactivate。
// 把 Creem 中间态翻译成契约 LicenseState；本地 revoked 优先于上游 active。
import type { AppContext } from "../context";
import { ApiError } from "../errors";
import type { UpstreamLicenseResult } from "../creem/client";
import { json } from "../responses";
import { parseActivate, parseValidate, parseDeactivate } from "../validation";
import { licenseFingerprint } from "../crypto";
import {
  isLocallyRevokedByFingerprint,
  isLocallyRevokedByLicenseKeyId,
  upsertAppMapping,
} from "../db";

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

function statusFromUpstream(r: UpstreamLicenseResult): LicenseStatus {
  if (r.status === "active") return "active";
  if (r.status === "expired") return "expired";
  return "revoked"; // inactive（Creem inactive/disabled）
}

function toState(r: UpstreamLicenseResult, status: LicenseStatus, validatedAt: string): LicenseState {
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
  const result = await ctx.license.activate(input.licenseKey, input.instanceName);
  const validatedAt = isoNoMillis(ctx.now());
  let status = statusFromUpstream(result);
  const fingerprint = await licenseFingerprint(ctx.env.LICENSE_HMAC_PEPPER, input.licenseKey);
  // 惰性登记 fingerprint ↔ license id，供本地 deny（运营吊销杠杆）后 validate 本地-优先命中。
  if (status === "active") {
    await upsertAppMapping(ctx.env.DB, { licenseKeyId: result.licenseKeyId, fingerprint, now: validatedAt });
    // 本地 deny 可能先于首次 activate 写入（当时本地只有 license id、没有 fingerprint）。
    // 映射写回后必须按上游刚返回的 id 再查一次，不能把一致性窗口内的上游 active 回给客户端。
    if (await isLocallyRevokedByLicenseKeyId(ctx.env.DB, result.licenseKeyId)) {
      status = "revoked";
    }
  }
  ctx.logger.info("license.activate", { fingerprint, status, instanceId: result.instanceId });
  return json(toState(result, status, validatedAt), 200);
}

export async function handleValidate(ctx: AppContext, body: unknown): Promise<Response> {
  const input = parseValidate(body);
  const fingerprint = await licenseFingerprint(ctx.env.LICENSE_HMAC_PEPPER, input.licenseKey);
  const validatedAt = isoNoMillis(ctx.now());

  // 先查本地 revoked（退款/拒付）——本地 deny 优先于上游 active。
  if (await isLocallyRevokedByFingerprint(ctx.env.DB, fingerprint)) {
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

  const result = await ctx.license.validate(input.licenseKey, input.instanceId);
  let status = statusFromUpstream(result);
  // 惰性登记映射（仅上游 active 时），让后续本地吊销能被本地-优先捕获。
  if (status === "active") {
    await upsertAppMapping(ctx.env.DB, { licenseKeyId: result.licenseKeyId, fingerprint, now: validatedAt });
    if (await isLocallyRevokedByLicenseKeyId(ctx.env.DB, result.licenseKeyId)) {
      status = "revoked";
    }
  }
  ctx.logger.info("license.validate", { fingerprint, status, instanceId: input.instanceId });
  return json(toState(result, status, validatedAt), 200);
}

export async function handleDeactivate(ctx: AppContext, body: unknown): Promise<Response> {
  const input = parseDeactivate(body);
  try {
    await ctx.license.deactivate(input.licenseKey, input.instanceId);
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

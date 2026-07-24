// Creem webhook handler：
//   1. 用原始请求字节计算 HMAC-SHA256(hex)，对 `creem-signature` 恒定时间比较；
//      验签成功才解析 JSON。Creem 签名不含时间戳 → 重放防御依赖事件 ID 幂等。
//   2. 以 payload 顶层事件 ID（evt_...）幂等（webhook_events 唯一约束），
//      重复投递返回 200 但不重复副作用。
//   3. checkout.completed → 审计登记（payload 不含 license key，无法建 entitlement；
//      吊销主路 = app validate 命中上游 disabled，见 docs/creem-integration.md）。
//   4. refund.created / dispute.created → 按 order 落永久 tombstone + 尽力吊销
//      已知 order 的 entitlement；无法可靠映射就只登记，不凭模糊字段吊销。
//   5. 未知事件 / 未知 product → 安全忽略（登记 + 200）。
import type { AppContext } from "../context";
import { ApiError } from "../errors";
import { json, errorResponse } from "../responses";
import { verifyCreemWebhook, licenseFingerprint } from "../crypto";
import { mapEvent, type CanonicalEvent } from "../creem/mapping";
import {
  recordWebhookEvent,
  markWebhookProcessed,
  revokeByFingerprint,
  revokeByOrder,
  recordRefundTombstone,
} from "../db";
import { intVar } from "../env";
import { readJsonBody } from "../validation";

export async function handleWebhook(ctx: AppContext, req: Request): Promise<Response> {
  const maxBytes = intVar(ctx.env.MAX_BODY_BYTES, 16384);

  // 原始字节（验签必须用原始 bytes，不能先反序列化再序列化）
  const body = await readJsonBody(req, maxBytes);
  const raw = body.bytes;

  const ok = await verifyCreemWebhook(ctx.env.CREEM_WEBHOOK_SECRET, raw, req.headers.get("creem-signature"));
  if (!ok) {
    ctx.logger.warn("webhook.signature_invalid", {});
    return errorResponse("invalid_request", 401, "Signature verification failed");
  }

  // 验签通过后才解析
  let payload: unknown;
  try {
    payload = JSON.parse(body.text);
  } catch {
    return errorResponse("invalid_request", 400, "Malformed JSON body");
  }

  const event = mapEvent(payload);
  if (!event) {
    return errorResponse("invalid_request", 400, "Unmappable event (missing event id)");
  }

  const now = isoNow(ctx);

  // product 白名单：非本产品事件安全忽略（登记幂等，不执行副作用）。
  if (!isForOurProduct(ctx, event)) {
    ctx.logger.warn("webhook.unknown_product", { eventId: event.eventId, eventType: event.eventType });
    await recordWebhookEvent(ctx.env.DB, event.eventId, event.eventType, now);
    await markWebhookProcessed(ctx.env.DB, event.eventId, now);
    return json({ received: true }, 200);
  }

  // 幂等登记
  const reg = await recordWebhookEvent(ctx.env.DB, event.eventId, event.eventType, now);
  if (!reg.isNew && reg.alreadyProcessed) {
    ctx.logger.info("webhook.duplicate", { eventId: event.eventId, eventType: event.eventType });
    return json({ received: true }, 200);
  }

  // 新登记，或上次副作用未完成（processed=0）→ 执行（幂等 upsert，安全重试）
  try {
    await dispatch(ctx, event, now);
    await markWebhookProcessed(ctx.env.DB, event.eventId, isoNow(ctx));
  } catch (err) {
    // 副作用失败：保留 processed=0，返回 5xx 让 Creem 重投（下次安全重试）
    ctx.logger.error("webhook.dispatch_failed", {
      eventId: event.eventId,
      eventType: event.eventType,
      error: err instanceof Error ? err.message : String(err),
    });
    if (err instanceof ApiError) throw err;
    throw new ApiError("internal_error");
  }

  return json({ received: true }, 200);
}

// 未配置（空/占位符）则不设限（放行，交由 dispatch 的可靠映射把关）。
function isConfigured(v: string | undefined): boolean {
  return !!v && !v.includes("PLACEHOLDER");
}
function isForOurProduct(ctx: AppContext, event: CanonicalEvent): boolean {
  const productId = ctx.env.CREEM_PRODUCT_ID;
  if (event.productId && isConfigured(productId)) return event.productId === productId;
  return true;
}

async function dispatch(ctx: AppContext, event: CanonicalEvent, now: string): Promise<void> {
  switch (event.eventType) {
    case "checkout.completed": {
      // 实测：payload 不含 license key → 无法建立 license↔order 映射，审计登记即完成。
      // entitlement 行由 app 路径（activate/validate 成功）惰性登记（db.upsertAppMapping）。
      ctx.logger.info("webhook.checkout_completed", {
        eventId: event.eventId,
        // 只记 order id（非 PII、非 secret），供退款审计对账。
        orderId: event.orderId ?? "(none)",
      });
      return;
    }
    case "refund.created":
    case "dispute.created": {
      const reason = event.eventType === "refund.created" ? "refund" : "dispute";
      // 将来 Creem 若在 payload 补 license 字段 → 直接按指纹精确吊销（当前实测不存在）。
      if (event.licenseKey) {
        const fingerprint = await licenseFingerprint(ctx.env.LICENSE_HMAC_PEPPER, event.licenseKey);
        const hit = await revokeByFingerprint(ctx.env.DB, { fingerprint, reason, now });
        ctx.logger.info("webhook.revoked_by_fingerprint", { eventId: event.eventId, reason, affected: hit });
      }
      if (event.orderId) {
        // 先永久保存退款事实（tombstone），再更新已知 order 的 entitlement。
        // Creem 流程里 app 路径拿不到 order id → 命中 0 行是常态；tombstone 保证
        // 未来任何补上 order↔license 映射的授予路径都不会把退款订单翻回 active。
        await recordRefundTombstone(ctx.env.DB, {
          orderId: event.orderId,
          reason,
          sourceEventId: event.eventId,
          now,
        });
        const affected = await revokeByOrder(ctx.env.DB, { orderId: event.orderId, reason, now });
        if (affected === 0) {
          ctx.logger.info("webhook.refund_tombstoned", { eventId: event.eventId, reason });
        }
        return;
      }
      // 既无 license 又无 order → 无法可靠映射，安全忽略（不吊销）
      ctx.logger.warn("webhook.revoke_unmappable", { eventId: event.eventId, reason });
      return;
    }
    default:
      // 未知事件：已登记，安全忽略
      ctx.logger.info("webhook.ignored", { eventId: event.eventId, eventType: event.eventType });
      return;
  }
}

function isoNow(ctx: AppContext): string {
  return ctx.now().toISOString().replace(/\.\d{3}Z$/, "Z");
}

// Polar webhook handler：
//   1. Standard Webhooks 验签（webhook-id/timestamp/signature，签名内容 id.timestamp.body，
//      含时间戳漂移校验防重放）；验签成功才解析 JSON。
//   2. 以 webhook-id 幂等（webhook_events 唯一约束），重复投递返回 200 但不重复副作用。
//   3. benefit_grant.created → active（不翻回 revoked）；benefit_grant.revoked/refund → 本地 revoked。
//   4. 未知事件 / 非本产品 benefit / 无法可靠映射 → 安全忽略（登记 + 200，不吊销）。
import type { AppContext } from "../context";
import { ApiError } from "../errors";
import { json, errorResponse } from "../responses";
import { verifyStandardWebhook } from "../crypto";
import { mapEvent, type CanonicalEvent } from "../polar/mapping";
import {
  recordWebhookEvent,
  markWebhookProcessed,
  upsertActiveEntitlement,
  revokeByLicenseKeyId,
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

  const webhookId = req.headers.get("webhook-id");
  const ok = await verifyStandardWebhook(
    ctx.env.POLAR_WEBHOOK_SECRET,
    raw,
    {
      id: webhookId,
      timestamp: req.headers.get("webhook-timestamp"),
      signature: req.headers.get("webhook-signature"),
    },
    { nowMs: ctx.now().getTime() },
  );
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

  const event = mapEvent(payload, webhookId);
  if (!event) {
    return errorResponse("invalid_request", 400, "Unmappable event (missing webhook id)");
  }

  const now = isoNow(ctx);

  // 白名单：非本 benefit / 非本 product 的事件安全忽略（登记幂等，不执行副作用）。
  if (!isForOurProduct(ctx, event)) {
    ctx.logger.warn("webhook.unknown_target", { eventId: event.eventId, eventType: event.eventType });
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
    // 副作用失败：保留 processed=0，返回 5xx 让 Polar 重投（下次安全重试）
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

// benefit → POLAR_BENEFIT_ID；order → POLAR_PRODUCT_ID。未配置（空/占位符）则不设限（放行）。
function isConfigured(v: string | undefined): boolean {
  return !!v && !v.includes("PLACEHOLDER");
}
function isForOurProduct(ctx: AppContext, event: CanonicalEvent): boolean {
  const benefitId = ctx.env.POLAR_BENEFIT_ID;
  const productId = ctx.env.POLAR_PRODUCT_ID;
  if (event.benefitId && isConfigured(benefitId)) return event.benefitId === benefitId;
  if (event.productId && isConfigured(productId)) return event.productId === productId;
  return true; // 无可判定字段或白名单未配置 → 交由 dispatch 的可靠映射把关
}

async function dispatch(ctx: AppContext, event: CanonicalEvent, now: string): Promise<void> {
  switch (event.eventType) {
    case "benefit_grant.created": {
      if (!event.licenseKeyId) {
        // grant 未带 license_key_id → 无法建立 join key，安全跳过
        ctx.logger.warn("webhook.grant_no_license_key", { eventId: event.eventId });
        return;
      }
      await upsertActiveEntitlement(ctx.env.DB, {
        licenseKeyId: event.licenseKeyId,
        orderId: event.orderId,
        customerId: event.customerId,
        benefitId: event.benefitId,
        productId: event.productId,
        sourceEventId: event.eventId,
        now,
      });
      ctx.logger.info("webhook.grant_created", { eventId: event.eventId, licenseKeyId: event.licenseKeyId });
      return;
    }
    case "benefit_grant.revoked": {
      if (event.licenseKeyId) {
        await revokeByLicenseKeyId(ctx.env.DB, {
          licenseKeyId: event.licenseKeyId,
          orderId: event.orderId,
          customerId: event.customerId,
          reason: "revoked",
          sourceEventId: event.eventId,
          now,
        });
        ctx.logger.info("webhook.revoked", { eventId: event.eventId, licenseKeyId: event.licenseKeyId });
        return;
      }
      ctx.logger.warn("webhook.revoke_no_license_key", { eventId: event.eventId });
      return;
    }
    case "order.refunded":
    case "refund.created": {
      // 兜底：Polar 通常也会发 benefit_grant.revoked 精确吊销；这里按 order 尽力吊销。
      const reason = event.eventType === "order.refunded" ? "refund" : "refund";
      if (event.orderId) {
        // 先保存退款事实，再更新已有 entitlement。若 grant 尚未来，后续 grant 的原子 upsert
        // 会命中 tombstone 并直接创建 revoked；不能把 0 行 UPDATE 当成已完成后丢掉退款。
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

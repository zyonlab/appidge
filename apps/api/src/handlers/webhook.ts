// Creem webhook handler：
//   1. 用原始请求字节计算 HMAC-SHA256，对 creem-signature 恒定时间比较；验签成功才解析 JSON。
//   2. 以真实事件 ID 幂等（webhook_events 唯一约束），重复投递返回 200 但不重复副作用。
//   3. checkout.completed → active（不翻回 revoked）；refund/dispute → 本地 revoked。
//   4. 未知事件 / 未知 product / 无法可靠映射 → 安全忽略（登记 + 200，不吊销）。
import type { AppContext } from "../context";
import { ApiError } from "../errors";
import { json, errorResponse } from "../responses";
import { verifyWebhookSignature, licenseFingerprint } from "../crypto";
import { mapEvent, type CanonicalEvent } from "../creem/mapping";
import {
  recordWebhookEvent,
  markWebhookProcessed,
  upsertActiveEntitlement,
  revokeByFingerprint,
  revokeByOrder,
} from "../db";
import { intVar } from "../env";

export async function handleWebhook(ctx: AppContext, req: Request): Promise<Response> {
  const maxBytes = intVar(ctx.env.MAX_BODY_BYTES, 16384);

  // 原始字节（验签必须用原始 bytes，不能先反序列化再序列化）
  const raw = await req.arrayBuffer();
  if (raw.byteLength > maxBytes) {
    return errorResponse("invalid_request", 400, "Request body too large");
  }

  const sig = req.headers.get("creem-signature");
  const ok = await verifyWebhookSignature(ctx.env.CREEM_WEBHOOK_SECRET, raw, sig);
  if (!ok) {
    ctx.logger.warn("webhook.signature_invalid", {});
    return errorResponse("invalid_request", 401, "Signature verification failed");
  }

  // 验签通过后才解析
  let payload: unknown;
  try {
    payload = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return errorResponse("invalid_request", 400, "Malformed JSON body");
  }

  const event = mapEvent(payload);
  if (!event) {
    return errorResponse("invalid_request", 400, "Unmappable event (missing event id)");
  }

  // product 白名单：非本产品事件安全忽略（登记幂等，不执行副作用）。
  if (event.productId && event.productId !== ctx.env.CREEM_PRODUCT_ID) {
    ctx.logger.warn("webhook.unknown_product", { eventId: event.eventId, eventType: event.eventType });
    await recordWebhookEvent(ctx.env.DB, event.eventId, event.eventType, isoNow(ctx));
    await markWebhookProcessed(ctx.env.DB, event.eventId, isoNow(ctx));
    return json({ received: true }, 200);
  }

  // 幂等登记
  const now = isoNow(ctx);
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

async function dispatch(ctx: AppContext, event: CanonicalEvent, now: string): Promise<void> {
  switch (event.eventType) {
    case "checkout.completed": {
      if (!event.licenseKey) {
        // checkout 没带 license → 无法建立指纹，安全跳过（登记但不建 entitlement）
        ctx.logger.warn("webhook.checkout_no_license", { eventId: event.eventId });
        return;
      }
      const fingerprint = await licenseFingerprint(ctx.env.LICENSE_HMAC_PEPPER, event.licenseKey);
      await upsertActiveEntitlement(ctx.env.DB, {
        fingerprint,
        orderId: event.orderId,
        customerId: event.customerId,
        productId: event.productId,
        sourceEventId: event.eventId,
        now,
      });
      ctx.logger.info("webhook.checkout_completed", { eventId: event.eventId, fingerprint });
      return;
    }
    case "refund.created":
    case "dispute.created": {
      const reason = event.eventType === "refund.created" ? "refund" : "dispute";
      if (event.licenseKey) {
        const fingerprint = await licenseFingerprint(ctx.env.LICENSE_HMAC_PEPPER, event.licenseKey);
        await revokeByFingerprint(ctx.env.DB, {
          fingerprint,
          orderId: event.orderId,
          customerId: event.customerId,
          reason,
          sourceEventId: event.eventId,
          now,
        });
        ctx.logger.info("webhook.revoked", { eventId: event.eventId, reason, fingerprint });
        return;
      }
      if (event.orderId) {
        const affected = await revokeByOrder(ctx.env.DB, { orderId: event.orderId, reason, now });
        if (affected === 0) {
          // refund 先于 checkout 到达且无 license：无法可靠映射 → 报告阻塞，不凭模糊字段吊销
          ctx.logger.warn("webhook.revoke_unmapped", { eventId: event.eventId, reason });
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

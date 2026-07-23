// ────────────────────────────────────────────────────────────────────────────
// Polar webhook 字段映射。Polar 采用 Standard Webhooks，事件信封为：
//   { type: "<event.type>", timestamp: "<iso>", data: { ... } }
// 幂等键用 HTTP 头 `webhook-id`（每次投递唯一，重试复用），不从 payload 猜。
//
// ✅ 关键优势（相对 Creem）：license-key benefit 的 grant 事件在
//    data.properties.license_key_id 直接携带 **license_key_id**（+ order_id/customer_id），
//    这是 app 路径（validate 上游返回同一 id）与 webhook 路径共享的稳定 join key，
//    因此可做 Creem 做不到的 per-license 精确吊销。
//
// 关注的事件：
//   benefit_grant.created  → 建立 entitlement（license 已发放）
//   benefit_grant.revoked  → 精确吊销（退款/拒付/订阅取消时 Polar 自动撤销 grant）
//   order.refunded         → 兜底：按 order 吊销（benefit_grant.revoked 通常也会来）
//   refund.created         → 兜底：按 order 吊销
// 其余事件安全忽略（登记 + 200）。
// ────────────────────────────────────────────────────────────────────────────

export type CanonicalEventType =
  | "benefit_grant.created"
  | "benefit_grant.revoked"
  | "order.refunded"
  | "refund.created"
  | "unknown";

export interface CanonicalEvent {
  eventId: string; // 幂等唯一键（来自 webhook-id 头）
  eventType: CanonicalEventType;
  licenseKeyId?: string; // benefit_grant.* 携带
  orderId?: string;
  customerId?: string;
  benefitId?: string;
  productId?: string;
  raw: Record<string, unknown>;
}

function asObject(v: unknown): Record<string, unknown> | undefined {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

function normalizeEventType(raw: string | undefined): CanonicalEventType {
  switch (raw) {
    case "benefit_grant.created":
    case "benefit_grant.revoked":
    case "order.refunded":
    case "refund.created":
      return raw;
    default:
      return "unknown";
  }
}

// eventId 由调用方传入（webhook-id 头）。payload 只提供 type + data。
export function mapEvent(payload: unknown, eventId: string | null): CanonicalEvent | null {
  const top = asObject(payload);
  if (!top) return null;
  if (!eventId) return null; // 无 webhook-id → 无法幂等 → 拒绝（400）

  const eventType = normalizeEventType(str(top.type));
  const data = asObject(top.data) ?? {};

  const out: CanonicalEvent = { eventId, eventType, raw: top };

  if (eventType === "benefit_grant.created" || eventType === "benefit_grant.revoked") {
    const props = asObject(data.properties);
    out.licenseKeyId = str(props?.license_key_id);
    out.orderId = str(data.order_id);
    out.customerId = str(data.customer_id);
    out.benefitId = str(data.benefit_id);
    return out;
  }

  if (eventType === "order.refunded") {
    // data 为 Order 对象。
    out.orderId = str(data.id);
    out.customerId = str(data.customer_id);
    out.productId = str(data.product_id);
    return out;
  }

  if (eventType === "refund.created") {
    // data 为 Refund 对象，带 order_id。
    out.orderId = str(data.order_id);
    out.customerId = str(data.customer_id);
    return out;
  }

  return out; // unknown：仅 eventId + type，供登记幂等
}

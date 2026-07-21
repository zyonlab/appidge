// ────────────────────────────────────────────────────────────────────────────
// Creem webhook 字段映射（已用 test mode 真实 payload 实测确认，2026-07-21）。
// fixtures：contracts/fixtures/creem/{checkout.completed,refund.created,dispute.created}.json
//
// 实测确认的结构：
//   顶层 `id`(事件ID) + `eventType` + `object`；业务字段在 object 下：
//   object.order.{id,customer,product} · object.product.id(仅 checkout) · object.customer.{id,email}
//
// ⚠️ 关键事实：**Creem webhook 不携带 license key**（checkout/refund/dispute 都没有），
// 且 license API(validate/activate) 只回 product_id、**不回 order_id**。webhook 与 license API
// 没有公共 join key → **无法用 webhook 精确吊销某个 license**。因此吊销走 validate 主路：
// app 定期 validate → 我们的 facade 调 Creem validate → status=disabled/inactive → 映射为 revoked
// （见 handlers/licenses.ts statusFromCreem 与 creem/http.ts normalizeStatus）。webhook 的职责
// 收敛为「验签 + 幂等登记（审计）」，不再期望它驱动 per-license 吊销。
// 多候选键设计保留，便于将来 Creem 若在 payload 里补 license 字段时无痛接入。
// ────────────────────────────────────────────────────────────────────────────

export type CanonicalEventType = "checkout.completed" | "refund.created" | "dispute.created" | "unknown";

export interface CanonicalEvent {
  eventId: string; // 幂等唯一键
  eventType: CanonicalEventType;
  licenseKey?: string; // 若 payload 带 license → 用于指纹
  orderId?: string;
  customerId?: string;
  productId?: string;
  raw: Record<string, unknown>;
}

// 候选键名（按优先级）。拿到真实 fixture 后在这里增删。
const CANDIDATE_EVENT_ID = ["id", "event_id", "eventId"];
const CANDIDATE_EVENT_TYPE = ["eventType", "event_type", "type"];
const CANDIDATE_OBJECT = ["object", "data", "payload"];
const CANDIDATE_LICENSE = ["license", "license_key", "licenseKey", "key"];
const CANDIDATE_ORDER = ["order", "order_id", "orderId"];
const CANDIDATE_CUSTOMER = ["customer", "customer_id", "customerId"];
const CANDIDATE_PRODUCT = ["product", "product_id", "productId"];

function firstString(obj: Record<string, unknown>, keys: string[]): string | undefined {
  for (const k of keys) {
    const v = obj[k];
    if (typeof v === "string" && v.length > 0) return v;
    // 嵌套对象取 .id（如 order: { id: "..." }）
    if (v && typeof v === "object" && !Array.isArray(v)) {
      const id = (v as Record<string, unknown>).id;
      if (typeof id === "string" && id.length > 0) return id;
    }
  }
  return undefined;
}

function normalizeEventType(raw: string | undefined): CanonicalEventType {
  switch (raw) {
    case "checkout.completed":
    case "refund.created":
    case "dispute.created":
      return raw;
    default:
      return "unknown";
  }
}

export function mapEvent(payload: unknown): CanonicalEvent | null {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return null;
  const top = payload as Record<string, unknown>;

  const eventId = firstString(top, CANDIDATE_EVENT_ID);
  if (!eventId) return null; // 无法幂等 → 不可靠，拒绝（400）

  const eventType = normalizeEventType(firstString(top, CANDIDATE_EVENT_TYPE));

  // object 容器：优先从 object/data/payload 取业务字段，回退到顶层
  let obj: Record<string, unknown> = top;
  for (const k of CANDIDATE_OBJECT) {
    const v = top[k];
    if (v && typeof v === "object" && !Array.isArray(v)) {
      obj = v as Record<string, unknown>;
      break;
    }
  }

  return {
    eventId,
    eventType,
    licenseKey: firstString(obj, CANDIDATE_LICENSE),
    orderId: firstString(obj, CANDIDATE_ORDER),
    customerId: firstString(obj, CANDIDATE_CUSTOMER),
    productId: firstString(obj, CANDIDATE_PRODUCT),
    raw: top,
  };
}

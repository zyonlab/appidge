// ────────────────────────────────────────────────────────────────────────────
// Creem webhook 字段映射（结构已用 test mode 真实 payload 实测确认，2026-07-21 捕获，
// 2026-07 复核官方 docs.creem.io/code/webhooks 事件清单）。
// fixtures：contracts/fixtures/creem/{checkout.completed,refund.created,dispute.created}.json
//
// 实测确认的信封：
//   顶层 `id`(evt_..., 幂等键) + `eventType` + `created_at` + `object`；业务字段在 object 下：
//   object.order.{id,customer,product} · object.product.id(仅 checkout) · object.customer.{id,email}
//
// ⚠️ 关键事实（实测 + 官方 agent SKILL.md 查证）：**Creem webhook 不携带 license key**
// （checkout/refund/dispute 都没有），license API(validate/activate) 只回 product_id、
// **不回 order_id**。webhook 与 license API 没有公共 join key → **无法用 webhook 精确吊销
// 某个 license**。因此吊销主路走 validate：app 定期 validate → facade 调 Creem validate →
// status=disabled/inactive → 映射为 revoked（Dashboard 手动 disable 是运营侧吊销杠杆，
// 见 docs/creem-integration.md）。webhook 的职责收敛为「验签 + 幂等登记（审计）+
// 按 order 落退款 tombstone」，不凭模糊字段吊销。
// 多候选键设计保留，便于将来 Creem 若在 payload 里补 license 字段时无痛接入。
// ────────────────────────────────────────────────────────────────────────────

export type CanonicalEventType = "checkout.completed" | "refund.created" | "dispute.created" | "unknown";

export interface CanonicalEvent {
  eventId: string; // 幂等唯一键（payload 顶层 id，evt_...）
  eventType: CanonicalEventType;
  licenseKey?: string; // 若 payload 将来带 license → 用于指纹（当前实测不存在）
  orderId?: string;
  customerId?: string;
  productId?: string;
  raw: Record<string, unknown>;
}

function asObject(v: unknown): Record<string, unknown> | undefined {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

// 取候选键的字符串值；值为嵌套对象时取其 .id（如 order: { id: "ord_..." }）。
function firstString(obj: Record<string, unknown>, keys: string[]): string | undefined {
  for (const k of keys) {
    const v = obj[k];
    const s = str(v);
    if (s) return s;
    const nested = asObject(v);
    if (nested) {
      const id = str(nested.id);
      if (id) return id;
    }
  }
  return undefined;
}

// 候选键名（按优先级；首项对齐真实 fixture，其余为契约漂移容错）。
const CANDIDATE_EVENT_ID = ["id", "event_id", "eventId"];
const CANDIDATE_EVENT_TYPE = ["eventType", "event_type", "type"];
const CANDIDATE_OBJECT = ["object", "data", "payload"];
const CANDIDATE_ORDER = ["order", "order_id", "orderId"];
const CANDIDATE_CUSTOMER = ["customer", "customer_id", "customerId"];
const CANDIDATE_PRODUCT = ["product", "product_id", "productId"];

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
  const top = asObject(payload);
  if (!top) return null;

  const eventId = firstString(top, CANDIDATE_EVENT_ID);
  if (!eventId) return null; // 无法幂等 → 不可靠，拒绝（400）

  const eventType = normalizeEventType(firstString(top, CANDIDATE_EVENT_TYPE));

  // object 容器：优先从 object/data/payload 取业务字段，回退到顶层。
  let obj: Record<string, unknown> = top;
  for (const k of CANDIDATE_OBJECT) {
    const v = asObject(top[k]);
    if (v) {
      obj = v;
      break;
    }
  }

  // product：checkout 在 object.product.id；refund/dispute 只在 object.order.product。
  const order = asObject(obj.order);
  const productId = firstString(obj, CANDIDATE_PRODUCT) ?? (order ? firstString(order, CANDIDATE_PRODUCT) : undefined);
  const customerId =
    firstString(obj, CANDIDATE_CUSTOMER) ?? (order ? firstString(order, CANDIDATE_CUSTOMER) : undefined);

  // license：当前实测 payload 不存在；候选提取仅为将来 Creem 补字段时的无痛接入。
  const licenseObj = asObject(obj.license);
  const licenseKey = str(obj.license) ?? str(obj.license_key) ?? str(obj.licenseKey) ?? str(licenseObj?.key);

  return {
    eventId,
    eventType,
    licenseKey,
    orderId: firstString(obj, CANDIDATE_ORDER),
    customerId,
    productId,
    raw: top,
  };
}

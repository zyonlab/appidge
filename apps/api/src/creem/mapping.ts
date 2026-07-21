// ────────────────────────────────────────────────────────────────────────────
// ⚠️ 人工闸门（HUMAN GATE）：Creem webhook 字段映射
//
// 本模块是 Creem 上游 webhook payload → 我们内部规范事件的**唯一**翻译点。
// 目前字段名（event_id / eventType / order / license 等）来自 contracts/fixtures/creem/*.MOCK.json
// 占位样本，**未经 Creem test mode 实测确认**。
//
// 解锁步骤（人工）：
//   1. 在 Creem test mode 触发真实 checkout.completed / refund.created / dispute.created；
//   2. 抓取 raw webhook body，脱敏后替换 contracts/fixtures/creem/*.json 并去掉 _mock 标记；
//   3. 核对下方 CANDIDATE_* 候选键，删掉不存在的、补上真实键名；
//   4. 跑 webhook 契约测试。
//
// 设计为「多候选键 + 首个命中」，因此即便真实键名与占位略有出入也不硬失败，只需在此微调，
// 不触碰 handler 逻辑。绝不凭邮箱/模糊字段吊销（见 mapEvent 的 unmappable 处理）。
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

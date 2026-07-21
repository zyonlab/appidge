// D1 数据访问：webhook 幂等登记 + entitlement 状态。
// 纪律：只存 license 指纹，不存明文 key / 原始 payload / 非必要 PII。

export type EntitlementStatus = "active" | "revoked";

export interface EntitlementRow {
  license_fingerprint: string;
  order_id: string | null;
  customer_id: string | null;
  product_id: string | null;
  status: EntitlementStatus;
  reason: string | null;
  source_event_id: string | null;
  created_at: string;
  updated_at: string;
}

export interface WebhookEventRow {
  event_id: string;
  event_type: string;
  received_at: string;
  processed: number;
  processed_at: string | null;
}

// 登记 webhook 事件；返回它在本次是否为「新登记」（用于决定是否执行副作用）。
// 已存在且 processed=1 → 幂等重复，返回 { isNew:false, alreadyProcessed:true }。
// 已存在但 processed=0 → 上次副作用未完成，允许安全重试。
export async function recordWebhookEvent(
  db: D1Database,
  eventId: string,
  eventType: string,
  now: string,
): Promise<{ isNew: boolean; alreadyProcessed: boolean }> {
  const existing = await db
    .prepare("SELECT event_id, processed FROM webhook_events WHERE event_id = ?")
    .bind(eventId)
    .first<{ event_id: string; processed: number }>();

  if (existing) {
    return { isNew: false, alreadyProcessed: existing.processed === 1 };
  }
  await db
    .prepare("INSERT OR IGNORE INTO webhook_events (event_id, event_type, received_at, processed) VALUES (?, ?, ?, 0)")
    .bind(eventId, eventType, now)
    .run();
  return { isNew: true, alreadyProcessed: false };
}

export async function markWebhookProcessed(db: D1Database, eventId: string, now: string): Promise<void> {
  await db
    .prepare("UPDATE webhook_events SET processed = 1, processed_at = ? WHERE event_id = ?")
    .bind(now, eventId)
    .run();
}

// checkout.completed：置为 active，但**绝不把已 revoked 翻回 active**（退款/拒付优先）。
export async function upsertActiveEntitlement(
  db: D1Database,
  e: {
    fingerprint: string;
    orderId?: string;
    customerId?: string;
    productId?: string;
    sourceEventId: string;
    now: string;
  },
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO entitlements
         (license_fingerprint, order_id, customer_id, product_id, status, reason, source_event_id, created_at, updated_at)
       VALUES (?, ?, ?, ?, 'active', 'checkout', ?, ?, ?)
       ON CONFLICT(license_fingerprint) DO UPDATE SET
         order_id        = COALESCE(excluded.order_id, entitlements.order_id),
         customer_id     = COALESCE(excluded.customer_id, entitlements.customer_id),
         product_id      = COALESCE(excluded.product_id, entitlements.product_id),
         status          = CASE WHEN entitlements.status = 'revoked' THEN 'revoked' ELSE 'active' END,
         reason          = CASE WHEN entitlements.status = 'revoked' THEN entitlements.reason ELSE 'checkout' END,
         updated_at      = excluded.updated_at`,
    )
    .bind(
      e.fingerprint,
      e.orderId ?? null,
      e.customerId ?? null,
      e.productId ?? null,
      e.sourceEventId,
      e.now,
      e.now,
    )
    .run();
}

// refund/dispute：置为 revoked。可能先于 checkout 到达（用指纹 upsert 建行）。
export async function revokeByFingerprint(
  db: D1Database,
  e: { fingerprint: string; orderId?: string; customerId?: string; reason: string; sourceEventId: string; now: string },
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO entitlements
         (license_fingerprint, order_id, customer_id, product_id, status, reason, source_event_id, created_at, updated_at)
       VALUES (?, ?, ?, NULL, 'revoked', ?, ?, ?, ?)
       ON CONFLICT(license_fingerprint) DO UPDATE SET
         status       = 'revoked',
         reason       = excluded.reason,
         order_id     = COALESCE(excluded.order_id, entitlements.order_id),
         customer_id  = COALESCE(excluded.customer_id, entitlements.customer_id),
         updated_at   = excluded.updated_at`,
    )
    .bind(e.fingerprint, e.orderId ?? null, e.customerId ?? null, e.reason, e.sourceEventId, e.now, e.now)
    .run();
}

// 无 license 指纹时按 order 吊销（refund 只带 order 的情形）。返回受影响行数。
export async function revokeByOrder(
  db: D1Database,
  e: { orderId: string; reason: string; now: string },
): Promise<number> {
  const res = await db
    .prepare("UPDATE entitlements SET status = 'revoked', reason = ?, updated_at = ? WHERE order_id = ?")
    .bind(e.reason, e.now, e.orderId)
    .run();
  return res.meta.changes ?? 0;
}

export async function getEntitlement(db: D1Database, fingerprint: string): Promise<EntitlementRow | null> {
  return await db
    .prepare("SELECT * FROM entitlements WHERE license_fingerprint = ?")
    .bind(fingerprint)
    .first<EntitlementRow>();
}

// 本地是否已 revoke（refund/dispute）。用于 validate 时本地 deny 优先于上游 active。
export async function isLocallyRevoked(db: D1Database, fingerprint: string): Promise<boolean> {
  const row = await getEntitlement(db, fingerprint);
  return row?.status === "revoked";
}

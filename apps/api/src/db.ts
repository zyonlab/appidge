// D1 数据访问：webhook 幂等登记 + entitlement 状态。
// entitlements 以 Polar license_key_id 为主键（webhook 与 app 路径共享的稳定 join key）；
// license_fingerprint 为 app 路径惰性填充的索引列（validate 本地-优先吊销用）。
// 纪律：只存 license 指纹，不存明文 key / 原始 payload / 非必要 PII。

export type EntitlementStatus = "active" | "revoked";

export interface EntitlementRow {
  license_key_id: string;
  license_fingerprint: string | null;
  order_id: string | null;
  customer_id: string | null;
  benefit_id: string | null;
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

export interface RefundTombstoneRow {
  order_id: string;
  reason: string;
  source_event_id: string;
  created_at: string;
  updated_at: string;
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

// benefit_grant.created：置为 active，但**绝不把已 revoked 翻回 active**（退款/拒付优先）。
export async function upsertActiveEntitlement(
  db: D1Database,
  e: {
    licenseKeyId: string;
    orderId?: string;
    customerId?: string;
    benefitId?: string;
    productId?: string;
    sourceEventId: string;
    now: string;
  },
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO entitlements
         (license_key_id, license_fingerprint, order_id, customer_id, benefit_id, product_id, status, reason, source_event_id, created_at, updated_at)
       VALUES (
         ?, NULL, ?, ?, ?, ?,
         CASE
           WHEN ? IS NOT NULL AND EXISTS (
             SELECT 1 FROM refund_tombstones WHERE order_id = ?
           ) THEN 'revoked'
           ELSE 'active'
         END,
         CASE
           WHEN ? IS NOT NULL THEN COALESCE(
             (SELECT reason FROM refund_tombstones WHERE order_id = ?),
             'grant'
           )
           ELSE 'grant'
         END,
         ?, ?, ?
       )
       ON CONFLICT(license_key_id) DO UPDATE SET
         order_id    = COALESCE(excluded.order_id, entitlements.order_id),
         customer_id = COALESCE(excluded.customer_id, entitlements.customer_id),
         benefit_id  = COALESCE(excluded.benefit_id, entitlements.benefit_id),
         product_id  = COALESCE(excluded.product_id, entitlements.product_id),
         status      = CASE
           WHEN entitlements.status = 'revoked' OR excluded.status = 'revoked' THEN 'revoked'
           ELSE 'active'
         END,
         reason      = CASE
           WHEN entitlements.status = 'revoked' THEN entitlements.reason
           WHEN excluded.status = 'revoked' THEN excluded.reason
           ELSE 'grant'
         END,
         updated_at  = excluded.updated_at`,
    )
    .bind(
      e.licenseKeyId,
      e.orderId ?? null,
      e.customerId ?? null,
      e.benefitId ?? null,
      e.productId ?? null,
      e.orderId ?? null,
      e.orderId ?? null,
      e.orderId ?? null,
      e.orderId ?? null,
      e.sourceEventId,
      e.now,
      e.now,
    )
    .run();
}

// benefit_grant.revoked：按 license_key_id 精确吊销。可能先于 grant 到达（用 id upsert 建行）。
export async function revokeByLicenseKeyId(
  db: D1Database,
  e: { licenseKeyId: string; orderId?: string; customerId?: string; reason: string; sourceEventId: string; now: string },
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO entitlements
         (license_key_id, license_fingerprint, order_id, customer_id, benefit_id, product_id, status, reason, source_event_id, created_at, updated_at)
       VALUES (?, NULL, ?, ?, NULL, NULL, 'revoked', ?, ?, ?, ?)
       ON CONFLICT(license_key_id) DO UPDATE SET
         status      = 'revoked',
         reason      = excluded.reason,
         order_id    = COALESCE(excluded.order_id, entitlements.order_id),
         customer_id = COALESCE(excluded.customer_id, entitlements.customer_id),
         updated_at  = excluded.updated_at`,
    )
    .bind(e.licenseKeyId, e.orderId ?? null, e.customerId ?? null, e.reason, e.sourceEventId, e.now, e.now)
    .run();
}

// 无 license_key_id 时按 order 吊销（order.refunded/refund.created 兜底）。返回受影响行数。
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

// refund.created / order.refunded 可能先于 benefit_grant.created 到达。先永久记录 order tombstone，
// 后来的 grant 在同一条原子 upsert 中检查它，绝不会把已退款订单创建成 active。
export async function recordRefundTombstone(
  db: D1Database,
  e: { orderId: string; reason: string; sourceEventId: string; now: string },
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO refund_tombstones (order_id, reason, source_event_id, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(order_id) DO UPDATE SET
         reason = excluded.reason,
         source_event_id = excluded.source_event_id,
         updated_at = excluded.updated_at`,
    )
    .bind(e.orderId, e.reason, e.sourceEventId, e.now, e.now)
    .run();
}

// app 路径（activate/validate 成功）惰性登记 fingerprint ↔ license_key_id 映射。
// **绝不把已 revoked 翻回 active**；仅补全 fingerprint 供 validate 本地-优先命中。
export async function upsertAppMapping(
  db: D1Database,
  e: { licenseKeyId: string; fingerprint: string; customerId?: string; now: string },
): Promise<void> {
  if (!e.licenseKeyId) return; // 上游未回 id（异常）→ 不写脏行
  await db
    .prepare(
      `INSERT INTO entitlements
         (license_key_id, license_fingerprint, order_id, customer_id, benefit_id, product_id, status, reason, source_event_id, created_at, updated_at)
       VALUES (?, ?, NULL, ?, NULL, NULL, 'active', 'app', NULL, ?, ?)
       ON CONFLICT(license_key_id) DO UPDATE SET
         license_fingerprint = COALESCE(excluded.license_fingerprint, entitlements.license_fingerprint),
         customer_id         = COALESCE(excluded.customer_id, entitlements.customer_id),
         updated_at          = excluded.updated_at`,
    )
    .bind(e.licenseKeyId, e.fingerprint, e.customerId ?? null, e.now, e.now)
    .run();
}

export async function getEntitlementByLicenseKeyId(db: D1Database, licenseKeyId: string): Promise<EntitlementRow | null> {
  return await db
    .prepare("SELECT * FROM entitlements WHERE license_key_id = ?")
    .bind(licenseKeyId)
    .first<EntitlementRow>();
}

export async function getRefundTombstoneByOrder(
  db: D1Database,
  orderId: string,
): Promise<RefundTombstoneRow | null> {
  return await db
    .prepare("SELECT * FROM refund_tombstones WHERE order_id = ?")
    .bind(orderId)
    .first<RefundTombstoneRow>();
}

export async function isLocallyRevokedByLicenseKeyId(db: D1Database, licenseKeyId: string): Promise<boolean> {
  if (!licenseKeyId) return false;
  const row = await db
    .prepare("SELECT status FROM entitlements WHERE license_key_id = ? LIMIT 1")
    .bind(licenseKeyId)
    .first<{ status: string }>();
  return row?.status === "revoked";
}

// 本地是否已 revoke（退款/拒付）。validate 时本地 deny 优先于上游 active。
// 按 fingerprint 查（app 只知道 licenseKey→fingerprint，不知道 license_key_id）。
export async function isLocallyRevokedByFingerprint(db: D1Database, fingerprint: string): Promise<boolean> {
  const row = await db
    .prepare("SELECT status FROM entitlements WHERE license_fingerprint = ? AND status = 'revoked' LIMIT 1")
    .bind(fingerprint)
    .first<{ status: string }>();
  return row?.status === "revoked";
}

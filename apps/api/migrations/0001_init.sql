-- 0001_init.sql — webhook 幂等 + entitlement/refund 状态
-- 纪律：不存完整 license key（只存 HMAC fingerprint）、不存原始支付 payload、不存非必要 PII。

-- webhook_events：以真实 Creem 事件 ID 唯一约束，实现幂等。
-- processed=0 表示已登记但副作用尚未成功（允许安全重试）；=1 表示已完成。
CREATE TABLE IF NOT EXISTS webhook_events (
  event_id     TEXT PRIMARY KEY NOT NULL,
  event_type   TEXT NOT NULL,
  received_at  TEXT NOT NULL,
  processed    INTEGER NOT NULL DEFAULT 0,
  processed_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_webhook_events_type ON webhook_events(event_type);

-- entitlements：授权状态。license 只以 HMAC(pepper, licenseKey) 指纹保存。
-- status: active | revoked。revoked 一旦置位不被 checkout 翻回（退款/拒付优先）。
CREATE TABLE IF NOT EXISTS entitlements (
  license_fingerprint TEXT PRIMARY KEY NOT NULL,
  order_id            TEXT,
  customer_id         TEXT,
  product_id          TEXT,
  status              TEXT NOT NULL DEFAULT 'active',
  reason              TEXT,
  source_event_id     TEXT,
  created_at          TEXT NOT NULL,
  updated_at          TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_entitlements_order ON entitlements(order_id);
CREATE INDEX IF NOT EXISTS idx_entitlements_customer ON entitlements(customer_id);
CREATE INDEX IF NOT EXISTS idx_entitlements_status ON entitlements(status);

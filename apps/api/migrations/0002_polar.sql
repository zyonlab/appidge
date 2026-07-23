-- 0002_polar.sql — 从 Creem 切换到 Polar.sh 的 entitlements 重建。
-- 背景：Creem 从未上生产、无真实 entitlement 数据；Polar webhook 只携带
-- license_key_id（不含明文 key），而 app 路径只知道 licenseKey→fingerprint。
-- 因此把 entitlements 的主键从 license_fingerprint 改为 license_key_id（两条路共享的
-- 稳定 join key），license_fingerprint 降为 app 路径惰性填充的索引列。
-- SQLite 无法 ALTER 主键 → 直接重建（安全：切换发生在上线前，退款状态可从上游重新推导）。

DROP INDEX IF EXISTS idx_entitlements_order;
DROP INDEX IF EXISTS idx_entitlements_customer;
DROP INDEX IF EXISTS idx_entitlements_status;
DROP TABLE IF EXISTS entitlements;

-- entitlements：授权状态。license 只以 Polar license_key_id + HMAC fingerprint 保存，
-- 绝不存明文 license key。
-- status: active | revoked。revoked 一旦置位不被 grant/app 翻回（退款/拒付优先）。
CREATE TABLE IF NOT EXISTS entitlements (
  license_key_id      TEXT PRIMARY KEY NOT NULL,
  license_fingerprint TEXT,            -- app 路径（activate/validate）惰性填充；webhook 路径为空
  order_id            TEXT,
  customer_id         TEXT,
  benefit_id          TEXT,
  product_id          TEXT,
  status              TEXT NOT NULL DEFAULT 'active',
  reason              TEXT,
  source_event_id     TEXT,
  created_at          TEXT NOT NULL,
  updated_at          TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_entitlements_fingerprint ON entitlements(license_fingerprint);
CREATE INDEX IF NOT EXISTS idx_entitlements_order ON entitlements(order_id);
CREATE INDEX IF NOT EXISTS idx_entitlements_customer ON entitlements(customer_id);
CREATE INDEX IF NOT EXISTS idx_entitlements_status ON entitlements(status);

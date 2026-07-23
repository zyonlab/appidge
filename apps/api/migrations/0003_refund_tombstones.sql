-- 0003_refund_tombstones.sql — 保存先于 entitlement/grant 到达的退款事实。
-- order.refunded / refund.created 一旦验签通过即按 order_id 落 tombstone；后续 grant 的
-- 原子 upsert 会检查该表并直接创建 revoked entitlement，避免乱序事件把退款用户翻回 active。

CREATE TABLE IF NOT EXISTS refund_tombstones (
  order_id        TEXT PRIMARY KEY NOT NULL,
  reason          TEXT NOT NULL,
  source_event_id TEXT NOT NULL,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_refund_tombstones_updated ON refund_tombstones(updated_at);

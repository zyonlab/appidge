# contracts/fixtures

契约测试用的脱敏 请求/响应/webhook fixtures。两类，别混：

1. **facade/** —— 本仓库 Worker facade 的对外契约（`licensing.openapi.yaml` 的实例）。
   由我们定义，稳定，Swift/TS 双端契约测试都读它。**当前可用。**

2. **polar/** —— Polar **上游** webhook payload 的脱敏样本。
   信封为 `{ type, timestamp, data }`：`benefit_grant.created.json` / `benefit_grant.revoked.json` /
   `order.refunded.json`。
   ✅ 关键（相对 Creem 的改进）：license-key benefit 的 grant 事件在
   `data.properties.license_key_id` 直接携带 **license_key_id**（+ `order_id`/`customer_id`），
   这是 app 路径（validate 上游返回同一 id）与 webhook 路径共享的稳定 join key，
   因此可做 per-license 精确吊销。见 `apps/api/src/polar/mapping.ts` 顶部注释与
   `docs/polar-integration.md`。
   ⚠️ 这些 fixture 目前据 Polar OpenAPI schema 构造（标注 `TODO(polar)`）；上线前用 sandbox test mode
   真实捕获替换并核对字段。**这些 webhook 不含明文 license key**（只有 license_key_id）。

## 纪律

- 所有 fixture 一律脱敏：无完整 license key、无真实客户邮箱/订单号、无 API key。
- mock 值统一用 `MOCK_` / `0000` / `example.com` 前缀，便于 grep 确认没有真值泄漏。
- facade 响应 fixture 必须能通过 `licensing.openapi.yaml` 的 schema 校验（Agent C 的契约测试断言这点）。

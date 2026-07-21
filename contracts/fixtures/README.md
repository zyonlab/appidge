# contracts/fixtures

契约测试用的脱敏 请求/响应/webhook fixtures。两类，别混：

1. **facade/** —— 本仓库 Worker facade 的对外契约（`licensing.openapi.yaml` 的实例）。
   由我们定义，稳定，Swift/TS 双端契约测试都读它。**当前可用。**

2. **creem/** —— Creem **上游**真实 webhook payload 的脱敏样本。
   ✅ 已用 Creem test mode 实测捕获并脱敏（2026-07-21）：`checkout.completed.json` /
   `refund.created.json` / `dispute.created.json`。结构：顶层 `id`+`eventType`+`object`，
   业务字段在 `object.order.{id,customer,product}` 等。
   ⚠️ 关键：**这些 webhook 都不含 license key**；且 license API 只回 product_id、不回 order_id，
   两侧无公共 join key → 吊销走 validate 主路（Creem status），webhook 只做验签+幂等登记。见
   `apps/api/src/creem/mapping.ts` 顶部注释与 `docs/creem-integration.md`。

## 纪律

- 所有 fixture 一律脱敏：无完整 license key、无真实客户邮箱/订单号、无 API key。
- mock 值统一用 `MOCK_` / `0000` / `example.com` 前缀，便于 grep 确认没有真值泄漏。
- facade 响应 fixture 必须能通过 `licensing.openapi.yaml` 的 schema 校验（Agent C 的契约测试断言这点）。

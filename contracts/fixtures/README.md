# contracts/fixtures

契约测试用的脱敏 请求/响应/webhook fixtures。两类，别混：

1. **facade/** —— 本仓库 Worker facade 的对外契约（`licensing.openapi.yaml` 的实例）。
   由我们定义，稳定，Swift/TS 双端契约测试都读它。**当前可用。**

2. **creem/** —— Creem **上游** webhook payload 的脱敏样本。
   ✅ **真实来源**：2026-07-21 在 Creem test mode 用真实购买/退款/拒付捕获（邮箱等已脱敏），
   非按文档构造。信封为顶层 `{ id, eventType, created_at, object }`：
   `checkout.completed.json` / `refund.created.json` / `dispute.created.json`。
   ⚠️ 关键事实（实测 + Creem 官方 agent SKILL.md 查证）：**三种事件都不携带 license key**，
   payload 是订单中心（`object.order.{id,customer,product}`）；license API 也不回 order id。
   webhook 与 license API 没有公共 join key → 无法用 webhook 精确吊销某个 license，
   吊销主路走 validate（Dashboard disable → status=disabled → facade 映射 revoked）。
   见 `apps/api/src/creem/mapping.ts` 顶部注释与 `docs/creem-integration.md`。

## 纪律

- 所有 fixture 一律脱敏：无完整 license key、无真实客户邮箱/订单号、无 API key。
- mock 值统一用 `MOCK_` / `TEST` / `0000` / `example.com` 前缀，便于 grep 确认没有真值泄漏。
- facade 响应 fixture 必须能通过 `licensing.openapi.yaml` 的 schema 校验（契约测试断言这点）。

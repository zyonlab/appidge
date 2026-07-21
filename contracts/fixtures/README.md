# contracts/fixtures

契约测试用的脱敏 请求/响应/webhook fixtures。两类，别混：

1. **facade/** —— 本仓库 Worker facade 的对外契约（`licensing.openapi.yaml` 的实例）。
   由我们定义，稳定，Swift/TS 双端契约测试都读它。**当前可用。**

2. **creem/** —— Creem **上游**真实 payload 的脱敏样本（webhook / license API）。
   ⚠️ 字段名（`event_id` / order / license key 字段）**必须用 Creem test mode 实测捕获后脱敏**，
   不得凭猜测填。当前只有 `*.MOCK.json` 占位，标注 `"_mock": true`；
   拿到 test secret 后用真实脱敏样本替换，去掉 `_mock` 标记，再让 webhook 处理逻辑依赖确切字段名。

## 纪律

- 所有 fixture 一律脱敏：无完整 license key、无真实客户邮箱/订单号、无 API key。
- mock 值统一用 `MOCK_` / `0000` / `example.com` 前缀，便于 grep 确认没有真值泄漏。
- facade 响应 fixture 必须能通过 `licensing.openapi.yaml` 的 schema 校验（Agent C 的契约测试断言这点）。

# Creem 集成基线 — license facade（apps/api）

> 本轮由 Polar 换回 Creem（creem.io，同为 Merchant of Record）。本仓库 2026-07-21~22 做过一轮
> 完整的 Creem test 模式实测（买→activate→validate→退款→disable→validate 全链路 + 真实 webhook
> 捕获），本文档的关键结论都有实测出处；端点/签名细节已于 2026-07 按官方文档
> （docs.creem.io）复核。facade 对 App 的契约（`contracts/licensing.openapi.yaml`）零改动。

## 0. 一句话架构

App「输入 key → activate → 存 instance id → 定期 validate」不变；facade Worker 持有
`CREEM_API_KEY`（x-api-key），客户端绝不直连 Creem。**吊销主路 = validate**（Dashboard 手动
disable license → 上游 status=disabled → facade 映射 `revoked`）；webhook 只做
验签 + 幂等审计 + 按 order 落退款 tombstone。

## 1. License API（官方文档已复核）

三端点全 `POST`，头 `x-api-key: <CREEM_API_KEY>`，`Content-Type: application/json`。
Base：生产 `https://api.creem.io`，test `https://test-api.creem.io`（两环境完全隔离，key 各自独立，
test key 前缀 `creem_test_`）。

| 端点 | body | 返回 |
|---|---|---|
| `/v1/licenses/activate` | `{ key, instance_name }` | LicenseEntity（`instance.id` 必须本地存） |
| `/v1/licenses/validate` | `{ key, instance_id }` | LicenseEntity |
| `/v1/licenses/deactivate` | `{ key, instance_id }` | LicenseEntity（释放实例名额，**不等于 disable key**） |

LicenseEntity 关键字段：`id`（license 对象 id，我们的本地 join key）、
`status ∈ inactive|active|expired|disabled`、`expires_at`（买断为 null）、`activation`、
`activation_limit`（null=无限）、`instance`。错误码：400/401/404；无文档化的错误枚举 →
facade 用 4xx body 的 code/error/message 关键词最小翻译（limit→`activation_limit`、
expire→`expired`，兜底 `invalid_license`），5xx/timeout→`upstream_unavailable`，429→`rate_limited`。

**status 映射**（`apps/api/src/creem/http.ts normalizeStatus`，实测坐实）：
`active`→active（`expires_at` 已过→expired）；`expired`→expired；`disabled`/`inactive`→facade
`revoked`；未知/缺失状态一律按 transient（`upstream_unavailable`）进宽限，绝不误翻 revoked。

出处：docs.creem.io/api-reference/endpoint/{activate,validate,deactivate}-license（2026-07 WebFetch 复核）。

## 2. Webhook（签名机制与 Polar 完全不同）

- 配置：Creem 后台 Developers → Webhooks；**staging 已配置**指向
  `https://api-staging.appidge.com/v1/webhooks/creem`，secret 前缀 `whsec_`。
- **验签**：头 `creem-signature` = `hex(HMAC-SHA256(secret, rawBody))`，对原始请求字节计算，
  恒定时间比较。**secret 按 Dashboard 显示的字面值使用**——官方手动验签示例
  `createHmac('sha256', secret)` 直接传字符串，`whsec_` 前缀不剥离、不做 base64 解码
  （与 Polar 的 Standard Webhooks 两码事，别混）。
- **没有 webhook-id / webhook-timestamp 头** → 签名不含时间戳，无漂移窗口可校验；
  重放防御 = payload 顶层事件 ID（`id: "evt_..."`）的幂等登记（`webhook_events` 唯一约束，
  重复投递 200 但不重复副作用）。
- 重试策略（官方）：30s/1min/5min/1h 渐进退避，可在 Dashboard 手动重发。
- 事件信封（**真实 test mode 捕获**，见 `contracts/fixtures/creem/*.json`）：
  顶层 `{ id, eventType, created_at, object }`，业务字段在 `object` 下。

出处：docs.creem.io/code/webhooks（2026-07 WebFetch 复核：header 名、HMAC-SHA256 hex、事件清单）。

## 3. 事件与处理（`apps/api/src/handlers/webhook.ts`）

| 事件 | payload 要点（实测） | facade 行为 |
|---|---|---|
| `checkout.completed` | `object.order.{id,customer,product}`、`object.product.id`；**不含 license key** | 验签+幂等登记（审计），不建 entitlement |
| `refund.created` | `object.order.{id,product}`；不含 license key | order tombstone + 按 order 尽力吊销 |
| `dispute.created` | 同上 | 同上，reason=dispute |
| 其他（subscription.* 等） | — | 登记后安全忽略 |

product 白名单：`CREEM_PRODUCT_ID` 不匹配的事件登记后忽略（staging=test 产品
`prod_19wdgqeFewovz4fWqITeaX`；production 为 REQUIRED_ 占位）。

## 4. 为什么吊销走 validate（2026-07-21/22 实测结论，本轮沿用）

- webhook 三种事件都**不带 license key**；license API 有 license 无 order → **无公共 join key**，
  无法用 webhook 精确吊销某个 license（官方 agent SKILL.md 亦查证：无按 order/customer 查
  license 的 API；license key 只出现在邮件/订单确认/客户门户）。
- **退款不会自动 disable license**（真实退款后直连 validate 仍返回 active）。
- **Dashboard 手动 disable 生效**：disable 后 validate=disabled → facade=revoked。
- ⇒ 运营流程：退款/拒付时在 Creem Dashboard 处理退款的同时**手动 disable 该 license**；
  App 每日 validate 即锁定。webhook 落库仅作审计/对账提醒。
- 本地 deny 仍优先于上游 active（`entitlements.status=revoked` → validate 直接返回 revoked），
  运营也可直接在 D1 写 revoked 作为最后杠杆（`wrangler d1 execute … UPDATE entitlements …`）。

## 5. 配置与 secret 名单

| 名称 | 类型 | 值/来源 |
|---|---|---|
| `CREEM_API_BASE` | var | test `https://test-api.creem.io` / prod `https://api.creem.io` |
| `CREEM_PRODUCT_ID` | var | staging=`prod_19wdgqeFewovz4fWqITeaX`；production=REQUIRED_ 占位 |
| `CREEM_API_KEY` | **secret** | `wrangler secret put CREEM_API_KEY --env staging`（creem_test_…） |
| `CREEM_WEBHOOK_SECRET` | **secret** | `wrangler secret put CREEM_WEBHOOK_SECRET --env staging`（whsec_…，字面值） |
| `LICENSE_HMAC_PEPPER` | **secret** | 沿用，不轮换 |

支付链接：staging `https://www.creem.io/test/payment/prod_19wdgqeFewovz4fWqITeaX`；
production 待用户过 KYC 后提供 live 链接（`REQUIRED_CREEM_LIVE_CHECKOUT_URL`，不得含 `/test/`）。

## 6. fixture 来源

`contracts/fixtures/creem/{checkout.completed,refund.created,dispute.created}.json` 为
**2026-07-21 Creem test mode 真实 webhook 捕获**（邮箱等已脱敏），从 git 历史
（Polar 迁移前）原样恢复——非按文档构造。facade fixtures（`fixtures/facade/`）未动。

## 7. 人工闸门（主 agent / 用户）

1. `wrangler secret put CREEM_API_KEY / CREEM_WEBHOOK_SECRET --env staging`（值在用户手里）。
2. `appidge-ops deploy-api staging --apply` 后 smoke：test 支付链接买一单 → 邮件拿 key →
   facade activate/validate 走通 → Dashboard 退款 + disable → validate=revoked；
   同时确认 `/v1/webhooks/creem` 收到 checkout/refund 事件且验签通过（若新版 payload 字段
   与 fixture 有出入，抓新样本脱敏更新 fixtures + mapping）。
3. production：KYC → live 产品/链接/product id → 填 `REQUIRED_*` → preflight 过 → 三重保护部署。

## 8. 后续债务 / 风险

- `PUBLIC_POLAR_CHECKOUT_URL` / `POLAR_CHECKOUT_URL`（web）变量名未随品牌改（牵动另一 agent
  所有权的 components/check-site），下轮统一改名为 `PUBLIC_CHECKOUT_URL`。
- webhook secret 的「字面值 HMAC」按官方示例实现；若线上验签 401，first check：Dashboard 复制
  的 secret 是否含 `whsec_` 前缀差异（`signCreemWebhook` 有测试 helper 可比对）。
- Creem 若未来在 payload 里补 license 字段，`mapping.ts` 的候选键 + `revokeByFingerprint`
  已预留精确吊销路径，无痛接入。
- 退款→吊销依赖运营手动 disable（Creem 平台限制），上线 runbook 里必须写死这一步。

## 9. 历史参考

- 早期完整调研（payout/费率/KYC/回跳签名等）：git 历史 `docs/creem-integration.md`
  （commit `b167f21`，Polar 迁移 `6841f0b` 时删除）。回跳（success_url）签名是普通
  SHA256（`k=v|...|salt=apiKey`），与 webhook HMAC 是两套——v1 不做回跳自动灌 key，仅备忘。
- Polar 时期基线：`docs/polar-integration.md`（已标废弃，保留供对照）。

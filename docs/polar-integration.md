# Polar.sh 集成基线 — 原生 macOS App(Developer ID)

> 由 Creem 迁移而来（口碑因素）。本文档据 Polar 官方 OpenAPI（`https://sandbox-api.polar.sh/openapi.json`）+ 官方文档核实；标注 `⚠️需sandbox实测` 的项在上线前用真实 sandbox 复核。license API 与 webhook 验签方案清晰；退款→吊销的自动行为已从 schema 推断，仍以 sandbox 实测为准。

## 0. 一句话结论
Polar 满足场景：**MoR 收款 + License Keys benefit（activate/validate/deactivate 设备级端点）+ Standard Webhooks**。Mac app 只需本地「输入 key → activate → 存激活态 → 定期 validate」小状态机，全部经我们自有 facade Worker，客户端不持 Polar token。

## 0.5 相对 Creem 的关键改进 —— **可 per-license 精确吊销**

Creem 的死结：webhook 不带 license、license API 不回 order → 无公共 join key → 只能靠「Dashboard 手动 disable + validate 主路」吊销。**Polar 不同：**

- **join key = `license_key_id`**，两条路都拿得到：
  - app 路径：`validate`/`activate` 响应直接返回该 license key 的 `id`（=license_key_id）。
  - webhook 路径：`benefit_grant.created` / `benefit_grant.revoked` 的 `data.properties.license_key_id` 直接携带。
- **退款/拒付/订阅取消时 Polar 自动撤销 benefit grant** → 上游 license `status` 自动变 `revoked`，并触发 `benefit_grant.revoked`。⚠️需sandbox实测（据 schema + 文档推断，应无需 Dashboard 手动操作）。
- ⇒ **吊销双保险**：
  1. **主路 = validate**：app 定期 validate → facade 调 Polar validate → 退款后上游自动 `revoked`。（`polar/http.ts normalizeStatus` + `handlers/licenses.ts statusFromUpstream`）
  2. **旁路 = webhook 精确吊销**：`benefit_grant.revoked` 带 license_key_id → 本地 entitlement 标 revoked（按 license_key_id 键）→ 后续 validate 本地-优先命中，先于上游。（`handlers/webhook.ts` + `db.ts revokeByLicenseKeyId`）
- 无论上游行为如何，**本地 deny 状态都使后续 validate 返回 revoked**（对齐 CLAUDE.md §5.4）。

## 1. 账号 / 环境
- **sandbox**：base `https://sandbox-api.polar.sh`，独立于生产，免 KYC 即可跑通全套。
- **生产**：base `https://api.polar.sh`，收真钱需过 onboarding（MoR，法律主体/税务）。
- **组织级 access token**：前缀 `polar_oat_`（organization access token），服务端密钥，仅 Worker secret binding 持有，绝不进客户端/前端/日志。
- **organization_id**：每次 license API 调用必带（非秘密标识，走 wrangler [vars] / .dev.vars）。

## 2. 产品 & License Keys benefit
- 支持**一次性买断**与**订阅**。
- License key 由「**License Keys benefit**」发放：在 Product 上挂该 benefit，购买即自动发 key。
- benefit 可配：`limit_activations`（设备数上限，`null`=无限）、`expires`（有效期）、`limit_usage`（用量配额）。
- LicenseKeyStatus 枚举：**`granted` / `revoked` / `disabled`**。facade 映射：`granted`→active（除非 `expires_at` 已过→expired）；`revoked`/`disabled`→revoked。

## 3. 结账
- **Hosted Checkout Link（推荐起步，无代码）**：Product 上挂 checkout link，app「购买」按钮 → `NSWorkspace.open(url)`。官网同链接。
- **key 送达**：购买确认邮件 + **Polar 客户门户（customer portal）**。v1 不做浏览器回跳自动灌 key —— 用户从邮件/门户复制 key 回 App 粘贴激活。

## 4. License API（组织级端点，核心）
三端点全 `POST`，头 `Authorization: Bearer <polar_oat_...>`，`Content-Type: application/json`，body 必带 `organization_id`。

- **activate** `POST /v1/license-keys/activate` — body `{ key, organization_id, label }`。
  返回 `LicenseKeyActivationRead`：顶层 `id`(=**activation id**，即我们的 instanceId) + `license_key_id` + 嵌套 `license_key`（含 status/expires_at/limit_activations/usage）。
  **activation id 必须本地存**，后续 validate/deactivate 都要用。（`label` 即激活实例名，隐私友好的稳定安装标识）
- **validate** `POST /v1/license-keys/validate` — body `{ key, organization_id, activation_id? }`。
  返回 `LicenseKeyRead`：`{ id, status, expires_at, limit_activations, usage, validations, activation? }`。带 `activation_id` 校验特定设备实例。
- **deactivate** `POST /v1/license-keys/deactivate` — body `{ key, organization_id, activation_id }`。释放设备名额。
- 设备数由 benefit 的 `limit_activations` 控制；超限 activate 报错（Polar 返回 4xx，facade 映射 `activation_limit`）。⚠️需sandbox实测确切错误形态。
- 另有客户级端点 `/v1/customer-portal/license-keys/*`（客户会话令牌），我们**不用**——facade 用组织级端点。

## 5. Webhook：退款/拒付/退订 → 吊销
- Polar 面板 **Settings → Webhooks** 配置 endpoint（指向 `https://api.appidge.com/v1/webhooks/polar`）+ 拿 secret。
- 关注事件：`benefit_grant.created` / `benefit_grant.revoked` / `order.refunded` / `refund.created`（订阅启用后加 `subscription.canceled|revoked`）。
- **验签 = Standard Webhooks**（与 Creem 裸 HMAC 不同）：
  - 头：`webhook-id`、`webhook-timestamp`、`webhook-signature`。
  - secret：面板给的 endpoint secret，通常前缀 `whsec_`，其余为 base64（验签前 base64 解码）。
  - signedContent = `` `${webhook-id}.${webhook-timestamp}.${rawBody}` ``。
  - expected = `base64(HMAC-SHA256(secretBytes, signedContent))`；`webhook-signature` 为空格分隔的 `v1,<base64sig>`，任一恒定时间匹配即通过。
  - 额外校验时间戳漂移（±5min）防重放。
  - 实现见 `apps/api/src/crypto.ts verifyStandardWebhook`；官方 SDK `@polar-sh/sdk/webhooks` 的 `validateEvent` 等价。
- **payload 信封**：`{ type, timestamp, data }`。幂等键用 `webhook-id` 头（每次投递唯一，重试复用）。
- **精确吊销**：`benefit_grant.revoked.data.properties.license_key_id` → `revokeByLicenseKeyId`。
- **兜底**：`order.refunded`/`refund.created` 只带 order（无 license_key_id）→ 按 `order_id` 尽力吊销；映射不到就等随后的 `benefit_grant.revoked` 或上游 validate 自动 revoked，**不凭模糊字段乱吊销**。

## 6. 离线处理（客户端，未变）
- 激活态缓存 `{ key, activation_id(instanceId), status, expires_at, lastValidatedAt }`，全部进 **Keychain**。
- **宽限期**：启动 validate；联网成功以返回为准；Worker/Polar 暂时不可用（网络/5xx/timeout）进 grace（默认 7 天），**不立即 revoke**；明确 `revoked`/`expired` 才锁定。
- **防时钟回拨**：记录单调来源，防调回系统时间无限续宽限。

## 7. 后台准备清单（人工闸门）
- [ ] 注册 Polar，创建 organization，拿 **organization_id**。
- [ ] 建 Product（买断/订阅），挂 **License Keys benefit**，设 `limit_activations`。
- [ ] 拿该产品 **Hosted Checkout Link**（填官网 `PUBLIC_POLAR_CHECKOUT_URL` 与 App 构建配置）。
- [ ] 建 **organization access token**（`polar_oat_`）→ `wrangler secret put POLAR_ACCESS_TOKEN`。
- [ ] 配 Webhook endpoint（指向 `/v1/webhooks/polar`），记 secret → `wrangler secret put POLAR_WEBHOOK_SECRET`。
- [ ] 填 `POLAR_ORGANIZATION_ID` / `POLAR_PRODUCT_ID` / `POLAR_BENEFIT_ID`（wrangler [vars]）。
- [ ] sandbox 实测：买 → activate → validate(active) → 退款 → validate(应自动 revoked) + `benefit_grant.revoked` 落库。用真实脱敏 payload 替换 `contracts/fixtures/polar/*.json` 的 `TODO(polar)` 占位。
- [ ] 上线前完成生产 onboarding，切 `POLAR_API_BASE=https://api.polar.sh` + 生产 secret。

## 8. 风险 / 坑
1. **两种验签模型**：Polar=Standard Webhooks（`webhook-signature` 的 `v1,<b64>`，base64 密钥）；不要套用 Creem 的裸 hex HMAC。
2. **token 泄露**：`polar_oat_` 是服务端密钥，绝不嵌入分发 app → 强制经 facade Worker。
3. **退款自动吊销** 已据 schema/文档推断（Polar 自动撤 benefit grant），仍 `⚠️需sandbox实测` 坐实。
4. **webhook 不含明文 license key**，只有 `license_key_id`；不要期望从 webhook 拿原始 key。
5. **join key 是 license_key_id**：entitlements 以它为主键，`license_fingerprint` 为 app 路径惰性填充列（见 `migrations/0002_polar.sql`）。
6. **桌面无天然回跳** → v1 邮件/门户复制 key 粘贴。
7. **纯客户端授权可逆向绕过** → 独立工具通常可接受，别指望强防护；facade + Keychain + grace 是纵深防御。

### 主要来源
- OpenAPI（真相）：`https://sandbox-api.polar.sh/openapi.json`（license-keys/* 路径与 schema）
- License Keys benefit：https://polar.sh/docs/features/benefits/license-keys
- 组织级 license API：`/v1/license-keys/{validate,activate,deactivate}`（OpenAPI）
- Webhooks（Standard Webhooks 验签）：https://polar.sh/docs/integrate/webhooks/delivery · https://polar.sh/docs/integrate/webhooks/events
- 事件 payload 结构：OpenAPI `WebhookBenefitGrant*Payload` / `WebhookOrderRefundedPayload` / `BenefitGrantLicenseKeysProperties`

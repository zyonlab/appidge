# infra/cloudflare

非秘密的 Cloudflare 部署配置与说明。**任何 token/secret 都不进这里**（走 `wrangler secret` / GitHub protected secrets）。

## 线上拓扑（staging/production 双环境，全部 Workers + Static Assets，无 Pages/R2）

| 组件 | Staging | Production | 载体 |
|---|---|---|---|
| 官网（apps/web） | `staging.appidge.com` | `appidge.com` / `www.appidge.com` | Worker `appidge-web-*`，静态资源 |
| API（apps/api） | `api-staging.appidge.com`（MOCK_MODE=false，Creem test） | `api.appidge.com`（Creem live） | Worker `appidge-api-*` |
| 更新（infra/updates） | `updates-staging.appidge.com` | `updates.appidge.com` | Worker `appidge-updates-*`，静态资源托管 DMG/appcast（DMG >25MiB 才迁 R2） |
| D1 | `appidge-licensing-staging` | `appidge-licensing-production` `1db51c0e-9d4b-4b32-82f7-e02553508c11`（APAC，2026-07-24 创建） | 各一库，migrations `0001`~`0003` |

环境矩阵的单一真相源：`ops/environments/{staging,production}.conf`；
部署/校验统一入口：`ops/bin/appidge-ops`（runbook 见 `ops/README.md`）。

## D1

- Worker 的 D1 binding、migrations、schema 由 **apps/api** 拥有（`apps/api/migrations/`、`wrangler.toml`）。
- 本目录只放：环境划分说明、部署/回滚 runbook、非秘密的资源 ID 记录（如需要）。

## 部署 runbook（人工闸门 —— 需真实 Cloudflare 账号 + Creem test/生产 secret）

**统一入口是 `ops/bin/appidge-ops`（见 `ops/README.md`）**；它包含 preflight、三重生产保护和
dry-run。下面只记录底层原语（供理解/排障），**真实部署需用户授权**。

1. 创建 production D1 并回填 `wrangler.toml` 的 `[[env.production.d1_databases]].database_id`（占位为全 0）：
   ```bash
   wrangler d1 create appidge-licensing-production
   ```
2. 应用 migrations（`0001_init.sql` / `0002_polar.sql` / `0003_refund_tombstones.sql`）：
   ```bash
   ops/bin/appidge-ops migrate-api staging      # 无 --apply 只 list
   ops/bin/appidge-ops migrate-api staging --apply
   ```
3. 注入 secret（绝不写进 wrangler.toml / git）：
   ```bash
   wrangler secret put CREEM_API_KEY           --env production   # x-api-key（live key）
   wrangler secret put CREEM_WEBHOOK_SECRET    --env production   # whsec_...（creem-signature HMAC，Dashboard 字面值）
   wrangler secret put LICENSE_HMAC_PEPPER     --env production   # 高熵随机串
   ```
   （另需在 wrangler.toml `[env.production.vars]` 填非秘密的 `CREEM_PRODUCT_ID`，当前为 REQUIRED_ 占位。）
4. 校验与部署（production 需三重保护：`--apply --confirm-production` + `APPIDGE_PRODUCTION_APPROVED=YES`）：
   ```bash
   ops/bin/appidge-ops preflight production
   ops/bin/appidge-ops deploy-api staging --apply
   ```
5. 在 Creem 后台（Developers → Webhooks）配置 Webhook 指向 `https://api.appidge.com/v1/webhooks/creem`；**staging 已配置**（`https://api-staging.appidge.com/v1/webhooks/creem`，test 模式），记下 secret 用于第 3 步。

### 回滚

- Worker：`wrangler rollback --env production`（或 Dashboard 选上一 Deployment）。
- D1 migration 只增不改：回滚靠新 migration 补偿，不 `DROP` 生产表。

### 密钥轮换

- 在 Creem 生成新 key/secret → `wrangler secret put` 覆盖 → 部署 → 确认健康后作废旧 key。
- `LICENSE_HMAC_PEPPER` 轮换会使旧指纹失配：轮换需配套一次性重算 entitlements 指纹的迁移，或保留双 pepper 过渡窗口。默认不要轻易轮换 pepper。

### Creem webhook 字段映射（已实测）

`contracts/fixtures/creem/*.json` 为 2026-07-21 Creem test mode **真实捕获**（脱敏），映射逻辑
集中在 `apps/api/src/creem/mapping.ts`。部署后若发现新版 payload 字段漂移：抓新样本脱敏替换
fixture → 微调 mapping → 跑 webhook 测试。签名机制与吊销主路见 `docs/creem-integration.md`。

## Staging 部署实况（真实域名 appidge.com，Cloudflare 免费层）

Account ID `020878119352f1d4380269a2a334e17f`；zone `appidge.com`(active) `77d3b7f9…`。
分支 `staging` = 测试预览；`main` 以后 = 线上（见下「生产映射」）。

| 组件 | 资源 | URL |
|---|---|---|
| Worker（API） | `appidge-api-staging`（`[env.staging]`，**MOCK_MODE=false**，打 Creem test API） | **https://api-staging.appidge.com**（custom_domain，wrangler 自动建 DNS+证书） |
| D1 | `appidge-licensing-staging` `2777a4a3-8e0f-4f39-af39-12aed0ceb63e`（APAC） | 迁移共三条：`0001_init.sql` / `0002_polar.sql` / `0003_refund_tombstones.sql`（远端状态用 `appidge-ops migrate-api staging` 只读确认） |
| Worker secrets | `LICENSE_HMAC_PEPPER` / `CREEM_WEBHOOK_SECRET` / `CREEM_API_KEY` | 走 `wrangler secret put --env staging`，不入 git（旧 POLAR_* secret 部署后可 `wrangler secret delete` 清理） |
| 官网（Workers 静态资源） | Worker `appidge-web`（`[env.staging]`，`assets=./dist`，无 main） | 自定义域 **https://staging.appidge.com**（custom_domain，同 API 机制） |

**为什么官网也用 Worker（而非 Pages）**：Worker custom_domain 由 Workers API 自动建 DNS+证书，
token 的 Workers 权限即可；Pages custom_domain 依赖 zone 里的 CNAME，需 `Zone:DNS:Edit`
（当前 token 无此权限）。用 Workers 静态资源托管官网 → 与 API 同一套零手动 DNS 流程，静态资源请求免费层不计费。

已在 live 验证（第一轮 Creem 时期，MOCK_MODE + 真实远端 D1）：API healthz、activate/validate/
deactivate、篡改/缺签→401、官网 staging.appidge.com 首页/子页 200、无 secret 泄漏。
⚠️ **切回 Creem 后需重新 live 验证**（Polar 时期的 Standard Webhooks 验证已作废）：
`creem-signature` 验签（真实 secret）、checkout/refund 事件入库幂等、买→activate→validate→
Dashboard 退款+disable→validate=revoked 全链路、migrations 远端状态（`0002_polar.sql` 已应用过，
schema 兼容 Creem，无新增 migration）。

### 重新部署 staging
```bash
export CLOUDFLARE_ACCOUNT_ID=… CLOUDFLARE_API_TOKEN=…   # 不入 git
ops/bin/appidge-ops deploy-api staging --apply
ops/bin/appidge-ops deploy-web staging --apply   # 公开构建配置显式来自 ops/environments/staging.conf，不依赖 apps/web/.env
```
注意：`wrangler secret put` 后 secret 传播到运行实例有 ~10-15s 延迟，刚设完立刻打 webhook 可能 500，稍等即恢复。

### 生产映射（人工闸门，流程见 `ops/README.md` 与 free-plan 文档 Phase 6）
- Worker `appidge-api` `[env.production]` route → `api.appidge.com`（已入 `wrangler.toml`），MOCK_MODE=false + 真实 Creem live product id/secret（当前 REQUIRED_ 占位，preflight fail closed）。
- Worker `appidge-web` `[env.production]` route → `appidge.com` + `www.appidge.com`（配置已在 `apps/web/wrangler.jsonc`）。
- Worker `appidge-updates` `[env.production]` route → `updates.appidge.com`（Workers 静态资源；staging 已分离到 `updates-staging.appidge.com`，二者可并存）。
- production D1 `appidge-licensing-production`：✅ 已创建（`1db51c0e-9d4b-4b32-82f7-e02553508c11`，APAC）+ 回填 id + 三条 migration 已应用（2026-07-24）。
- ✅ 域名已统一为 `appidge.com`（prod: appidge.com / api.appidge.com / updates.appidge.com；staging: staging / api-staging / updates-staging 子域）。

## 状态

MVP 目标是 Cloudflare 免费层，但不作为可靠性假设——客户端有离线宽限兜底。
部署、回滚、密钥轮换步骤见本文件与 `docs/commercialization-status.md`。

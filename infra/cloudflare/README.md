# infra/cloudflare

非秘密的 Cloudflare 部署配置与说明。**任何 token/secret 都不进这里**（走 `wrangler secret` / GitHub protected secrets）。

## 线上拓扑（目标）

| 域名 | 服务 | 用途 |
|---|---|---|
| `appidge.com` | Cloudflare Pages | 静态官网（apps/web 产物） |
| `api.appidge.com` | Cloudflare Worker | license facade + Polar webhook（apps/api） |
| `updates.appidge.com` | R2 自定义域名 | DMG / appcast.xml / release notes，直达不经 Worker |

## D1

- Worker 的 D1 binding、migrations、schema 由 **apps/api** 拥有（`apps/api/migrations/`、`wrangler.toml`）。
- 本目录只放：环境划分说明、部署/回滚 runbook、非秘密的资源 ID 记录（如需要）。

## 部署 runbook（人工闸门 —— 需真实 Cloudflare 账号 + Polar sandbox/生产 secret）

以下命令在 `apps/api/` 下执行。**真实部署需用户授权**；当前仓库只做 dry-run / preview。

1. 创建 D1 并回填 `wrangler.toml` 的 `database_id`（占位为全 0）：
   ```bash
   wrangler d1 create appidge-licensing
   # 把输出的 database_id 填进 wrangler.toml 的 [[d1_databases]] 与 [[env.production.d1_databases]]
   ```
2. 应用 migrations（先本地后远端）：
   ```bash
   wrangler d1 migrations apply appidge-licensing --local      # 本地校验
   wrangler d1 migrations apply appidge-licensing --remote      # 生产（需授权）
   ```
3. 注入 secret（绝不写进 wrangler.toml / git）：
   ```bash
   wrangler secret put POLAR_ACCESS_TOKEN      --env production   # polar_oat_...（组织 access token）
   wrangler secret put POLAR_WEBHOOK_SECRET    --env production   # whsec_...（Standard Webhooks）
   wrangler secret put LICENSE_HMAC_PEPPER     --env production   # 高熵随机串
   ```
   （另需在 wrangler.toml [vars] 填非秘密的 `POLAR_ORGANIZATION_ID` / `POLAR_PRODUCT_ID` / `POLAR_BENEFIT_ID`。）
4. dry-run 校验绑定，再部署：
   ```bash
   wrangler deploy --dry-run --outdir dist --env=""              # 顶层环境
   wrangler deploy --env production                              # 生产（需授权）
   ```
5. 在 Polar 面板（Settings → Webhooks）配置 Webhook 指向 `https://api.appidge.com/v1/webhooks/polar`，记下 secret 用于第 3 步。

### 回滚

- Worker：`wrangler rollback --env production`（或 Dashboard 选上一 Deployment）。
- D1 migration 只增不改：回滚靠新 migration 补偿，不 `DROP` 生产表。

### 密钥轮换

- 在 Polar 生成新 token/secret → `wrangler secret put` 覆盖 → 部署 → 确认健康后作废旧 token。
- `LICENSE_HMAC_PEPPER` 轮换会使旧指纹失配：轮换需配套一次性重算 entitlements 指纹的迁移，或保留双 pepper 过渡窗口。默认不要轻易轮换 pepper。

### 人工闸门：Polar webhook 字段映射

`contracts/fixtures/polar/*.json` 目前据 Polar OpenAPI schema 构造（标 `TODO(polar)`），未经 sandbox 实测。
解锁见 `apps/api/src/polar/mapping.ts` 顶部注释：在 sandbox 抓真实 payload → 脱敏替换 fixture →
按需微调 `mapping.ts` 的字段提取 → 跑 webhook 契约测试。映射逻辑集中在该单一模块，可无痛替换。

## Staging 部署实况（真实域名 appidge.com，Cloudflare 免费层）

Account ID `020878119352f1d4380269a2a334e17f`；zone `appidge.com`(active) `77d3b7f9…`。
分支 `staging` = 测试预览；`main` 以后 = 线上（见下「生产映射」）。

| 组件 | 资源 | URL |
|---|---|---|
| Worker（API） | `appidge-api-staging`（`[env.staging]`，MOCK_MODE=true） | **https://api-staging.appidge.com**（custom_domain，wrangler 自动建 DNS+证书） |
| D1 | `appidge-licensing-staging` `2777a4a3-8e0f-4f39-af39-12aed0ceb63e`（APAC） | 迁移 `0001_init.sql` 已 apply --remote；**Polar 迁移 `0002_polar.sql` 待 apply --remote**（重建 entitlements） |
| Worker secrets | `LICENSE_HMAC_PEPPER` / `POLAR_WEBHOOK_SECRET` / `POLAR_ACCESS_TOKEN` | 走 `wrangler secret put --env staging`，不入 git |
| 官网（Workers 静态资源） | Worker `appidge-web`（`[env.staging]`，`assets=./dist`，无 main） | 自定义域 **https://staging.appidge.com**（custom_domain，同 API 机制） |

**为什么官网也用 Worker（而非 Pages）**：Worker custom_domain 由 Workers API 自动建 DNS+证书，
token 的 Workers 权限即可；Pages custom_domain 依赖 zone 里的 CNAME，需 `Zone:DNS:Edit`
（当前 token 无此权限）。用 Workers 静态资源托管官网 → 与 API 同一套零手动 DNS 流程，静态资源请求免费层不计费。

已在 live 验证（**Creem 时期**，MOCK_MODE + 真实远端 D1）：API healthz、activate/validate/deactivate、
篡改/缺签→401、官网 staging.appidge.com 首页/子页 200、无 secret 泄漏。
⚠️ **Polar 迁移后需重新 live 验证**：Standard Webhooks 验签、`benefit_grant.revoked`→本地 revoked、
退款后上游 validate 自动 revoked、`0002_polar.sql` apply --remote。旧 Creem `creem-signature`
refund→revoked 验证已作废（验签模型与吊销路径均已改）。

### 重新部署 staging
```bash
export CLOUDFLARE_ACCOUNT_ID=… CLOUDFLARE_API_TOKEN=…   # 不入 git
# API
cd apps/api && npx wrangler deploy --env staging
# 官网（构建期公开配置 PUBLIC_API_BASE_URL=https://api-staging.appidge.com 等经 apps/web/.env 注入）
cd apps/web && pnpm build && ../api/node_modules/.bin/wrangler deploy --env staging
```
注意：`wrangler secret put` 后 secret 传播到运行实例有 ~10-15s 延迟，刚设完立刻打 webhook 可能 500，稍等即恢复。

### 生产映射（待 main 上线时做）
- Worker `[env.production]` route → `api.appidge.com`（custom_domain），MOCK_MODE=false + 真实 Polar secret。
- Worker `appidge-web` `[env.production]` route → `appidge.com` + `www.appidge.com`（custom_domain；配置已在 `apps/web/wrangler.jsonc`）。
- R2 `updates.appidge.com`（Sparkle 包/appcast，需 EdDSA 公钥就绪后接）。
- ✅ 已统一为 `appidge.com`（prod: appidge.com / api.appidge.com / updates.appidge.com；staging 用 *-staging 子域）（含 App 内 `SUFeedURL` 与 license API base）。

## 状态

MVP 目标是 Cloudflare 免费层，但不作为可靠性假设——客户端有离线宽限兜底。
部署、回滚、密钥轮换步骤见本文件与 `docs/commercialization-status.md`。

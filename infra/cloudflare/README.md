# infra/cloudflare

非秘密的 Cloudflare 部署配置与说明。**任何 token/secret 都不进这里**（走 `wrangler secret` / GitHub protected secrets）。

## 线上拓扑（目标）

| 域名 | 服务 | 用途 |
|---|---|---|
| `appidge.app` | Cloudflare Pages | 静态官网（apps/web 产物） |
| `api.appidge.app` | Cloudflare Worker | license facade + Creem webhook（apps/api） |
| `updates.appidge.app` | R2 自定义域名 | DMG / appcast.xml / release notes，直达不经 Worker |

## D1

- Worker 的 D1 binding、migrations、schema 由 **apps/api** 拥有（`apps/api/migrations/`、`wrangler.toml`）。
- 本目录只放：环境划分说明、部署/回滚 runbook、非秘密的资源 ID 记录（如需要）。

## 部署 runbook（人工闸门 —— 需真实 Cloudflare 账号 + Creem test/生产 secret）

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
   wrangler secret put CREEM_API_KEY          --env production   # creem_live_... 或 creem_test_...
   wrangler secret put CREEM_WEBHOOK_SECRET    --env production   # whsec_...
   wrangler secret put LICENSE_HMAC_PEPPER     --env production   # 高熵随机串
   ```
4. dry-run 校验绑定，再部署：
   ```bash
   wrangler deploy --dry-run --outdir dist --env=""              # 顶层环境
   wrangler deploy --env production                              # 生产（需授权）
   ```
5. 在 Creem Dashboard 配置 Webhook 指向 `https://api.appidge.app/v1/webhooks/creem`，记下 secret 用于第 3 步。

### 回滚

- Worker：`wrangler rollback --env production`（或 Dashboard 选上一 Deployment）。
- D1 migration 只增不改：回滚靠新 migration 补偿，不 `DROP` 生产表。

### 密钥轮换

- 在 Creem 生成新 key/secret → `wrangler secret put` 覆盖 → 部署 → 确认健康后作废旧 key。
- `LICENSE_HMAC_PEPPER` 轮换会使旧指纹失配：轮换需配套一次性重算 entitlements 指纹的迁移，或保留双 pepper 过渡窗口。默认不要轻易轮换 pepper。

### 人工闸门：Creem webhook 字段映射

`contracts/fixtures/creem/*.MOCK.json` 为占位样本，字段名未经 test mode 实测。解锁见
`apps/api/src/creem/mapping.ts` 顶部注释：在 test mode 抓真实 payload → 脱敏替换 fixture →
按需微调 `mapping.ts` 的候选键 → 跑 webhook 契约测试。映射逻辑集中在该单一模块，可无痛替换。

## 状态

MVP 目标是 Cloudflare 免费层，但不作为可靠性假设——客户端有离线宽限兜底。
部署、回滚、密钥轮换步骤见本文件与 `docs/commercialization-status.md`。真实部署需用户授权，当前只做 dry-run / preview。

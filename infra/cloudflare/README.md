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

## 状态

MVP 目标是 Cloudflare 免费层，但不作为可靠性假设——客户端有离线宽限兜底。
部署、回滚、密钥轮换步骤见 `docs/commercialization-status.md`。真实部署需用户授权，当前只做 dry-run / preview。

---
name: cloudflare-free-stack
description: 用 Cloudflare 免费层（Workers + D1 + 静态资源托管）搭建 staging/production 双环境商业化后端的实战方案：声明式环境、fail-closed 运维 CLI、secret 分层。凡是要在 Cloudflare Workers/D1 上搭多环境（wrangler env）、给独立产品做零成本的官网+API+下载分发拓扑、设计 wrangler 部署与迁移流程、或纠结「免费层怎么安全上生产」时，务必先读本 skill——含可直接照抄的运维 CLI 设计模式。
---

# Cloudflare 免费层双环境实战方案

## 拓扑（免费层跑完整商业闭环）

参考拓扑：6 个 Worker + 2 个 D1 —— web/api/updates 三种角色 × staging/production 两环境，
每环境一个 D1。官网和更新包（安装器/appcast）都用 **Workers 静态资源托管**，注意**单文件
25 MiB 上限**——安装包超限时迁 R2，但**下载域名从第一天就定死**（如 `updates.<domain>`），
迁移时客户端零改动。大文件下载直达静态托管/R2，绝不过 API Worker 中转。

**免费层是成本目标，不是可靠性假设**：客户端必须有授权缓存 + 离线宽限，Worker 不可用不能
锁死付费用户；无 SLA 的组件故障要有降级路径。

## 环境模型：声明式，不是「创建」出来的

- 环境在 wrangler 配置里**声明**：`wrangler.toml` 的 `[env.staging]` / `[env.production]`
  段（各自的 vars、D1 binding、custom domain）。首次 `wrangler deploy --env <env>` 自动
  落地 Worker + custom domain + DNS/证书（前提：zone 在本账号）。
- **唯一需要手动创建的资源是 D1**（`wrangler d1 create <name>`，id 回填 wrangler.toml）。
  运维工具应刻意**不代建**（fail-closed）：检测到缺失只打印命令让人执行。
- Secret 分层要清晰：**已提交的都是公开值**（wrangler vars、per-env conf 文件、代码里的
  默认值），秘密只走 `wrangler secret put <NAME> --env <env>`（本地开发用 git-ignored 的
  `.dev.vars`，提供 `.dev.vars.example` 模板）。本地/CI 测试默认 mock 模式，不需要任何真 key。

## 运维 CLI 设计模式（值得照抄）

单一入口 `ops-cli <command> <staging|production>`，纯 POSIX sh + 每环境一个可提交的 conf
文件（只放公开值），无框架。关键机制：

- **默认 dry-run，`--apply` 才写**。production 再加三重保护：`--apply` +
  `--confirm-production` + 环境变量审批（如 `APPROVED=YES`），缺一 fail-closed。
- `preflight` 分两档：本地校验（配置矩阵完整性）与 `--remote` 只读远端检查——查 secret
  **名字**存在与否（绝不读值）、D1 存在、migrations 无 pending、wrangler 登录态。
- `plan` 打印完整发布计划但不动任何东西；`release` 一键串行 fail-fast。
- 部署后**断言产物**（如静态站里真的包含关键 CTA 链接）+ healthz smoke（失败提示
  `wrangler rollback --env <env>`）+ 发布清单记录产物 SHA-256。
- 配置矩阵写无网络的桩测试（环境值互不串、保护逻辑生效），跑在 CI 里。

## D1 纪律

- **不做 down migration**，出错只前滚补偿 migration。
- production migration 前记 Time Travel bookmark（免费层窗口 7 天）。
- migrations 用 `wrangler d1 migrations apply <name> --remote --env <env>`，本地/远端分清。
- 幂等键（如 webhook 事件 ID 唯一约束）放 DB 层，不放应用内存。

## 官网（Astro 静态 + Workers 托管）

- 构建期公开变量（站点 URL、checkout 链接、API base、下载链接）**缺失即 build 失败**——
  不偷偷回退到错误的生产地址。本地 `.env` 只服务开发预览；正式部署的值显式来自 per-env
  conf 经部署命令注入，两条路径不共享文件。
- CI 做内部链接检查 + 产物断言；无 JS 时核心内容与购买/下载链接仍可用。

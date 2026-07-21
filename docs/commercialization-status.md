# Appidge 商业化 Monorepo · 状态与人工闸门

> 只由主 Agent 更新勾选状态和证据。勾选前必须有可复现命令/输出证据，不凭主观标 pass。
> 缺真实凭证时，代码与自动测试完成 ≠ 上线完成——对应项保持未勾选，并给一条最短解锁步骤。

最后更新：2026-07-21（Phase 1 monorepo 地基）

## 图例
- [x] 已自动验证（有命令+输出）
- [~] 已实现，仅静态检查/mock，未接真实外部系统
- [ ] 未完成 / 阻塞在人工闸门

---

## Definition of Done（对齐 CLAUDE.md §8）

- [~] 现有 Swift/Xcode 路径未移动；根 pnpm/Turbo workspace 可重复安装并全绿
- [ ] CI 能按改动范围运行，main 集成闸门覆盖 Swift、Web、Worker
- [ ] Astro 官网含下载/购买/退款/隐私/条款并在 Cloudflare preview 验证
- [ ] Hosted Checkout test flow 能完成购买并获得 license key
- [ ] Worker license facade 不泄露 Creem API key，契约测试与错误映射全绿
- [ ] Webhook HMAC、D1 幂等、refund/dispute revoke 有自动测试与 sandbox 证据
- [ ] macOS App 用 Keychain 保存授权，activate/validate/deactivate 与 7 天 grace 全绿
- [ ] Sparkle 公钥、feed、签名更新包与 R2 路径真实可验证，不含 TODO 私钥
- [ ] 旧版 → 新版 Sparkle + 系统扩展升级 smoke test 有结果
- [ ] `swift test` 五包全绿，SwiftLint strict 全绿，App Debug build 成功
- [ ] `pnpm check` 全绿，Worker dry-run/preview 成功，仓库 secret 扫描无泄漏
- [ ] 部署/回滚/密钥轮换/退款操作/剩余人工闸门文档齐备

---

## 当前进度（Phase 1）

### 地基（主 Agent，serial）
- [~] pnpm workspace + Turborepo（root `package.json` / `pnpm-workspace.yaml` / `turbo.json`）
- [~] mock 秘密结构：`apps/api/.dev.vars`（MOCK）、`apps/web/.env`（公开配置），`.example` 已提交，真值 git-ignored
- [~] `contracts/licensing.openapi.yaml` v1 + facade fixtures + creem MOCK fixtures 占位
- [~] `infra/cloudflare/` 说明、本状态文档
- [ ] CI 路径感知（macOS ∥ web/api）—— 见 Agent A

### 并行 Wave（worktree 隔离）
- [ ] Agent B · apps/web（Astro 静态站）
- [ ] Agent C · apps/api（Worker facade + Creem mock + D1 + fixtures）
- [ ] Agent D · Sparkle 移植（从 `feat/sparkle-autoupdate`）

### Wave 2
- [ ] Agent E · macOS License Client
- [ ] Agent F · Integration/QA

---

## 人工闸门（需要用户 / 真实凭证 / 真实操作）

| 闸门 | 阻塞什么 | 最短解锁步骤 |
|---|---|---|
| Creem test key | 真实 activate/validate/deactivate 与真实 webhook fixture | 注册 creem.io（免卡）→ Settings→API Keys 拿 `creem_test_` key → 填入 `apps/api/.dev.vars`（MOCK_MODE=false） |
| Creem webhook secret | 真实 HMAC 验签 sandbox 证据 | Creem Developers→Webhook 配置 → 记 secret 填 `.dev.vars` |
| Creem 产品/checkout link | 官网购买按钮真实跳转 + 真实 license 送达 | 建 Product 开 License keys → 拿 Checkout Link 填 `apps/web/.env` |
| Cloudflare 部署 | Pages/Worker/R2/D1 真实上线 | `wrangler login` → 建 D1 → `wrangler secret put` 注入生产 secret（用户授权后） |
| Apple 签名/公证 | DMG 出包、系统扩展升级 smoke | 现有 `.env` + `scripts/`（已具备，出包时用） |
| Sparkle EdDSA 密钥 | 真实 appcast 签名 | `generate_keys` 生成，私钥留 Keychain/CI secret，公钥填 Info.plist `SUPublicEDKey` |

## 部署 / 回滚 / 密钥轮换 / 退款操作
> 占位，随 Agent C / D / F 落地补全。当前仅 dry-run，未做真实生产部署。

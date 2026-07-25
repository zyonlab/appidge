# Appidge 商业化 Monorepo · 状态与人工闸门

> ⚠️ **历史证据存档**：本文的勾选与命令输出是记录当时（≤2026-07-21）的验证结果，不代表当前线上状态。
> 当前双环境（staging/production）拓扑、发布入口与运维 runbook 以 `ops/README.md` 与
> `docs/claude-code-staging-production-free-plan.md` 为准；不要把本文历史勾选当作未经验证的线上事实。

> 只由主 Agent 更新勾选状态和证据。勾选前必须有可复现命令/输出证据，不凭主观标 pass。
> 缺真实凭证时，代码与自动测试完成 ≠ 上线完成——对应项保持未勾选，并给一条最短解锁步骤。

最后更新：2026-07-21（Phase 1 地基 + Wave 1 三 Agent 并行集成完成）

> **支付服务商迁移中：Creem → Polar.sh（Merchant of Record，代收款 + 代缴税）。**
> 官网（`apps/web`）已完成切换：结账走 Polar Hosted Checkout Link，环境变量已改名
> `PUBLIC_POLAR_CHECKOUT_URL`。`apps/api`（Worker facade / webhook / D1）与契约的迁移由对应
> owner 负责，尚未完成——下文历史记录中仍出现的 Creem，以及 API key/webhook secret/token 前缀/
> 环境变量名等技术标识，均以 `apps/api` 实际迁移结果为准，本文标 `TODO(polar): 待核实` 者不臆造。

## 图例
- [x] 已自动验证（有命令+输出）
- [~] 已实现，仅静态检查/mock，未接真实外部系统
- [ ] 未完成 / 阻塞在人工闸门

---

## Definition of Done（对齐 CLAUDE.md §8）

- [x] 现有 Swift/Xcode 路径未移动；根 pnpm/Turbo workspace 可重复安装（`pnpm install` frozen-able）并 `pnpm check` 全绿
- [~] CI 能按改动范围运行（`ci-swift` / `ci-web` 路径过滤，main push 跑全）—— 结构就位，尚未在 GitHub 实跑一次绿
- [~] Astro 官网含下载/购买/退款/隐私/条款 —— 本地 build/test 全绿；Cloudflare preview = 人工闸门
- [ ] Hosted Checkout test flow 能完成购买并获得 license key —— 需真实 Polar 产品/checkout link
- [x] Worker license facade 不泄露 Creem API key，契约测试与错误映射全绿（MOCK_MODE，44 测试）
- [~] Webhook HMAC、D1 幂等、refund/dispute revoke 有自动测试 —— sandbox 证据 = 人工闸门（真实 test secret + 脱敏 fixture）
- [x] macOS App 用 Keychain 保存授权，activate/validate/deactivate 与 7 天 grace 全绿（Core+AppFeature 授权测试；`xcodebuild App Debug` BUILD SUCCEEDED，真实签名）
- [~] Sparkle feed/包/R2 —— App target 接入且 Debug build 成功；`SUPublicEDKey` 仍为 TODO（未伪造）= 人工闸门
- [ ] 旧版 → 新版 Sparkle + 系统扩展升级 smoke test —— 发布期人工闸门
- [x] `swift test` 五包全绿、App Debug build 成功、**SwiftLint strict 0 违规**（预存 11 处已清零，见下「已解决」）
- [x] `pnpm check` 全绿（web+api：lint/typecheck/test/build），Worker `wrangler deploy --dry-run` 成功；提交物无 secret（.dev.vars/.env git-ignored）
- [~] 部署/回滚/密钥轮换文档：`infra/cloudflare/README.md` runbook 就位；退款操作/剩余闸门见下表

---

## 当前进度

集成后 `main` 线性历史（Phase 1 地基 → Sparkle → Website → Commerce → 集成）：
`d9e547a`(地基) → `1710844..b9e13f0`(Sparkle×4) → `d7eb9d6..dbfb350`(Website×3) → `ebf659c..12ffc35`(Commerce×5) → `72bb7e5`(集成 lockfile+turbo)。

### 地基（主 Agent，serial）— 完成
- [x] pnpm workspace + Turborepo（root `package.json` / `pnpm-workspace.yaml` / `turbo.json`）
- [x] mock 秘密结构：`apps/api/.dev.vars`（MOCK）、`apps/web/.env`（公开配置），`.example` 已提交，真值 git-ignored
- [x] `contracts/licensing.openapi.yaml` v1 + facade fixtures；creem `*.MOCK.json` 为占位（字段名待实测）
- [x] `infra/cloudflare/` runbook、本状态文档、CI 路径感知拆分（`ci-swift` / `ci-web`）

### Wave 1（三 Agent 并行，集成完成）
- [x] Agent B · apps/web（Astro 静态站）—— 7 路由+404、两路 CTA、SEO/OG/JSON-LD、无 JS 可用、脱敏与法律草稿标记；`typecheck`/`build`/`test` 全绿
- [x] Agent C · apps/api（Worker facade + Creem mock/http + webhook + D1）—— 44 测试全绿（38 workers-pool + 6 契约），`wrangler deploy --dry-run` 绿，redaction 断言无 key 泄漏
- [x] Agent D · Sparkle 移植 —— cherry-pick 3 提交零冲突 + feed 修正；`check-swift` 五包绿，`xcodebuild App Debug` BUILD SUCCEEDED，Extension 不链接 Sparkle 已核

### Wave 2（集成完成，分支 `feat/wave2-macos-licensing`）
- [x] Agent E · macOS License Client —— Core 纯授权状态机(相位机/DTO/协议注入) + AppFeature effect handler + App 侧 Keychain/URLSession/Clock 具体实现 + `LicenseSettingsView`；7 天宽限 + 时钟回拨高水位防护；**授权动作不产出任何路由 effect**（有测试断言，防授权故障黑洞网络）。`check-swift` 五包绿、`swiftlint` 0、`xcodebuild App Debug` SUCCEEDED。
- [x] Agent F · Integration/QA —— `scripts/smoke-license-mock.sh` 真实 wrangler dev 端到端 **17/17**（activate→validate→deactivate + 签名 refund webhook → validate 返回 revoked；篡改/缺签 → 401），契约一致性、官网、dry-run 全绿。证据与人工闸门 runbook 见 `docs/qa-evidence.md`。

集成全量闸门（主 Agent 复跑）：5 Swift 包绿 · SwiftLint strict 0(185 文件) · `xcodebuild App Debug` SUCCEEDED(真实签名) · `pnpm check` 8/8。

### 待接线（config，非阻塞）
- Release 已默认注入 `LicenseAPIBaseURL=https://api.appidge.com` 与稳定购买入口
  `LicenseCheckoutURL=https://appidge.com/#pricing`；归档脚本还会显式校验并注入这两个 HTTPS
  build setting。真实 Polar Checkout 由官网部署配置持有，替换链接无需重发 macOS App。
- ⚠️ **构建配置漂移警告**：`project.yml` 未含 Sparkle 包（Sparkle 只在 `project.pbxproj` 手工加入）。**不要跑 `xcodegen generate`**，否则会重生成 pbxproj 丢掉 Sparkle。修复方向：把 Sparkle 远程 SPM 包补进 `project.yml` 的 `packages:` 与 App target `dependencies:`，再 `xcodegen generate` 对齐——需人工核对生成结果与现有 pbxproj 一致后再提交。

## 已解决：SwiftLint strict 预存违规（commit `02f7955`）
11 处预存违规（`198d7a6` 即存在的 SwiftLint 版本漂移，非商业化改动引入）已清零：
- **行为保持真实修复（9）**：Core/Reducer 拆 `reduceConnectionLog`；Core/Action 换行；ExitIPChecker（`Data(str.utf8)` / 拆 `readSocks5ConnectReply` / 未用闭包参数 `_`）；SettingsView 两条长文案拼接换行；OnboardingView 与 …Routing 各把三元组换成结构体。
- **作用域豁免（2）**：`ProxyExtensionProvider` 的 `file_length` / `function_body_length` region-disable + 理由——转发热路径仅超阈值 2/21 行，稳定性零容忍下不为纯长度阈值重构热路径。
- 验证：`swiftlint --strict` 0 违规、`swift test` 五包全绿、`xcodebuild App Debug` BUILD SUCCEEDED。

---

## 人工闸门（需要用户 / 真实凭证 / 真实操作）

| 闸门 | 阻塞什么 | 最短解锁步骤 |
|---|---|---|
| Polar API/test token | 真实 activate/validate/deactivate 与真实 webhook fixture | 注册 polar.sh → Settings→拿 access token（token 前缀/`.dev.vars` 变量名由 `apps/api` 迁移决定，`TODO(polar): 待核实`）→ 填入 `apps/api/.dev.vars`（MOCK_MODE=false） |
| Polar webhook secret | 真实 HMAC 验签 sandbox 证据 | Polar Dashboard→Webhook 配置 → 记 secret 填 `.dev.vars`（变量名以 `apps/api` 为准，`TODO(polar): 待核实`） |
| Polar 产品/checkout link | 官网购买按钮真实跳转 + 真实 license 送达 | 建 Product 开 License keys → 拿 Hosted Checkout Link 填 `apps/web/.env` 的 `PUBLIC_POLAR_CHECKOUT_URL` |
| Cloudflare 部署 | Pages/Worker/R2/D1 真实上线 | `wrangler login` → 建 D1 → `wrangler secret put` 注入生产 secret（用户授权后） |
| Apple 签名/公证 | DMG 出包、系统扩展升级 smoke | 现有 `.env` + `scripts/`（已具备，出包时用） |
| Sparkle EdDSA 密钥 | 真实 appcast 签名 | `generate_keys` 生成，私钥留 Keychain/CI secret，公钥填 Info.plist `SUPublicEDKey` |

## 部署 / 回滚 / 密钥轮换 / 退款操作
> 占位，随 Agent C / D / F 落地补全。当前仅 dry-run，未做真实生产部署。

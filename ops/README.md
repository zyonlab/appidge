# ops —— Appidge staging/production 运维入口

单一入口：`ops/bin/appidge-ops <command> <staging|production> [options]`。
实施规格（给 Claude Code）：`docs/claude-code-staging-production-free-plan.md`；本文是给人的短 runbook。

## 布局

```text
ops/
├── bin/appidge-ops        # 唯一运维 CLI（POSIX sh）
├── environments/          # 每环境的公开配置（可提交、无 secret）
│   ├── staging.conf
│   └── production.conf
├── lib/common.sh          # 校验/保护公共库
└── tests/test-config.sh   # 无网络测试：环境矩阵 + 安全保护
```

`ops/environments/*.conf` 只保存公开值（域名、D1 名、公开 checkout 链接）。
secret 永远走 `wrangler secret put` / 根 `.env`（git-ignored）/ `.dev.vars`，绝不进这里。

## 环境拓扑（Cloudflare Free，6 Worker + 2 D1）

| 组件 | Staging | Production |
|---|---|---|
| Web | staging.appidge.com | appidge.com / www.appidge.com |
| API | api-staging.appidge.com（Creem test） | api.appidge.com（Creem live） |
| Updates | updates-staging.appidge.com | updates.appidge.com |
| D1 | appidge-licensing-staging | appidge-licensing-production |

⚠️ **macOS 身份共用**：staging/production 共用 Bundle ID、App Group、系统扩展 ID、签名身份与
Sparkle 公钥。两个 App **不能安全并存**——staging 安装会覆盖 production 安装，只能在内部测试
Mac 上装 staging 包。`CFBundleVersion` 是 staging/prod **共用的全局单调递增序列**；production
的 build 号必须高于任一 feed 上出现过的最高 build。

## 常用命令

```sh
ops/bin/appidge-ops show-config staging        # 脱敏公开配置
ops/bin/appidge-ops preflight staging          # 本地校验（全部问题逐项列出）
ops/bin/appidge-ops preflight staging --remote # + 只读远端检查（wrangler 登录/secret 名/D1/migrations）
ops/bin/appidge-ops plan production            # 打印发布计划，不改任何东西
ops/bin/appidge-ops test staging               # config 测试 + pnpm check + check:swift + wrangler dry-run
```

## 发布（staging）

一键（推荐;fail-fast,任一步失败即停）：

```sh
ops/bin/appidge-ops release staging --apply --build-number <N>
```

分步（排查/只做某一步时）：

```sh
ops/bin/appidge-ops migrate-api staging --apply
ops/bin/appidge-ops deploy-api  staging --apply
ops/bin/appidge-ops deploy-web  staging --apply
ops/bin/appidge-ops build-macos staging --build-number <N>     # 需本机 .env 签名/公证凭证
ops/bin/appidge-ops prepare-updates staging --build-number <N> # 本地生成+校验 appcast/DMG
ops/bin/appidge-ops publish-updates staging --apply --build-number <N>
ops/bin/appidge-ops smoke staging
ops/bin/appidge-ops release-manifest staging --build-number <N>
```

无 `--apply` 时以上写命令只打印计划/做 dry-run。

## 发布（production，三重保护）

production 的每个远端写命令必须同时满足，缺一 fail closed：

1. `--apply`
2. `--confirm-production`
3. 环境变量 `APPIDGE_PRODUCTION_APPROVED=YES`

```sh
ops/bin/appidge-ops preflight production --remote
ops/bin/appidge-ops plan production            # 人工核对后再继续
APPIDGE_PRODUCTION_APPROVED=YES ops/bin/appidge-ops migrate-api production --apply --confirm-production
APPIDGE_PRODUCTION_APPROVED=YES ops/bin/appidge-ops deploy-api  production --apply --confirm-production
APPIDGE_PRODUCTION_APPROVED=YES ops/bin/appidge-ops deploy-web  production --apply --confirm-production
ops/bin/appidge-ops build-macos production --build-number <N>
ops/bin/appidge-ops prepare-updates production --build-number <N>
# 首发专用：production feed 还不存在时，一次性放行该 feed 的单调性校验
# APPIDGE_ALLOW_MISSING_FEED=YES ops/bin/appidge-ops build-macos production --build-number <N>
APPIDGE_PRODUCTION_APPROVED=YES ops/bin/appidge-ops publish-updates production --apply --confirm-production --build-number <N>
ops/bin/appidge-ops smoke production
ops/bin/appidge-ops release-manifest production --build-number <N>
```

### production 解锁前提（人工闸门）

完整逐项清单见 **`docs/prod-launch-checklist.md`**（含每项现状：已备/待填/待配置 + 解锁步骤 + 回填位置一览）。
`preflight production` 会逐项列出缺失。当前必须由用户提供/执行（支付服务商为 Creem，非 Polar）：

- Creem live **product id** → 填 `apps/api/wrangler.toml [env.production.vars]` 的 `CREEM_PRODUCT_ID`（非秘密；Creem 无需 org/benefit id）。
- Creem live **支付链接** → 填 `ops/environments/production.conf` 的 `PUBLIC_POLAR_CHECKOUT_URL`（host creem.io，不含 /test/）。
- D1 `appidge-licensing-production` **已创建并迁移**（id 已回填 `wrangler.toml`）；上线前用 `preflight production --remote` 复核远端无 pending。
- `wrangler secret put CREEM_API_KEY|CREEM_WEBHOOK_SECRET|LICENSE_HMAC_PEPPER --env production`（值待 Creem live 阶段提供）。
- Creem live webhook → `https://api.appidge.com/v1/webhooks/creem`（路径 `/creem`）。
- `appidge.com` zone 已在本 Cloudflare 账号（custom_domain 自动建 DNS/证书的前提）。
- staging 全链路 smoke 通过 + production 发布审批。

## 回滚

- **API/Web/Updates（Worker）**：发布前 CLI 会列当前 deployments 作为回滚点；
  `wrangler rollback --env <env>` 或 Dashboard 恢复上一 deployment；恢复后重跑 `smoke`。
- **D1**：不做 down migration，用新的补偿 migration 前滚；Free 层 Time Travel 窗口 7 天，
  production migration 前记录 bookmark。
- **macOS 更新包**：已被下载的错误 build 不能靠降 build 号修复——必须发更高 build。
  每次 `release-manifest` 保存 appcast/DMG 的 SHA-256 以供审计。

## build 号单调性与 `APPIDGE_ALLOW_MISSING_FEED`

staging/production 共用一条**全局递增** build 序列。`build-macos` 会拉取两个 feed 求历史最高
build，新包必须严格更高——否则用户装到手的版本比线上更旧，且永远收不到更新。

首发有个死锁：`updates.appidge.com` 的 appcast 要到 `publish-updates` 才存在，而 `build-macos`
在它之前就要求该 feed 可查。用 `APPIDGE_ALLOW_MISSING_FEED=YES` 一次性放行。该开关的边界：

- 只免除**查不到的那个 feed**；可查的 feed 照旧强制单调。
- 两个 feed 都查不到时**也不放行**——没有任何单调性证据就不许出包。
- 值必须精确 `=YES`。

⚠️ 别设成常态、更别把该检查改成静默跳过——它是防"发了个比线上更旧的 build"的唯一护栏。
边界由 `ops/tests/test-config.sh` 的 9 条打桩测试守住（不联网）。

## 系统扩展版本解耦（升级黑洞的根本缓解）

app build 号每次出包递增（上节），**系统扩展版本不跟**：Extension 的
CFBundleShortVersionString / CFBundleVersion 读 project.yml 里钉住的
`APPIDGE_EXT_MARKETING_VERSION` / `APPIDGE_EXT_BUILD_NUMBER`，不受
`archive-and-notarize.sh` 命令行注入的 `CURRENT_PROJECT_VERSION` 影响。

为什么：macOS 按 (short, build) 元组判断系统扩展是否需要替换；替换窗口正是
「会话绑死旧 provider / XPC 监听器注册失败」竞态（升级黑洞）的唯一入口。
扩展内容没变的发版保持版本不动 → 系统跳过替换 → 竞态窗口不存在。

发版规则：

- **没改** `Extension/`、`Packages/EngineKit`、`Packages/IPCContract` → 什么都不用做，
  出包自动跳过扩展替换（`build-macos` 里守门闸会打印确认）。
- **改了**上述任一处 → 在 project.yml bump `APPIDGE_EXT_BUILD_NUMBER`（保持单调递增，
  与 app build 号无需一致），跑 `scripts/check-extension-version.sh --update` 登记，
  `xcodegen generate` 重生成工程，一起提交（含 `scripts/extension-version.lock`）。
- 守门闸（`archive-and-notarize.sh` §0.6）对两个方向都硬失败：内容变了没 bump
  （用户永远跑旧扩展、版本握手失明）、内容没变乱 bump（无谓重开替换窗口）。
- 盲区：ProxyExtension 的构建设置 / Xcode SDK 变更不进指纹；确需强制替换时
  bump 后 `--update` 显式登记。
- 回归测试：`ops/tests/test-extension-version.sh`（不联网）。

## 边界

- 开发命令（`pnpm dev:web` / `dev:api` / `check` / `check:swift`）不需要任何云凭证，API 默认 mock。
- Web/API 开发不读根 Apple `.env`；原生构建不读 Cloudflare/Polar secret。
- macOS 签名、公证、Sparkle 私钥、updates 发布留在受控 release Mac。
- Workers 静态资源单文件上限 25 MiB（Free）：`prepare/publish-updates` 会硬性检查，
  超限时拒绝发布并提示迁移 DMG 到 R2（域名不变）。

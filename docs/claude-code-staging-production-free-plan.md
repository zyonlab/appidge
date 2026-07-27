# Claude Code 执行规格：Cloudflare Free 上的 Staging / Production 双环境

> 创建日期：2026-07-24
>
> 基线提交：`3bf9522d219b78984a2569d4cf6c78543b2e7a31`
>
> 方案：方案 A——两个环境使用相同 macOS Bundle ID、App Group、系统扩展 ID 和签名身份，只隔离网络入口、云资源、Polar 环境和更新通道。
> 配套分析：[`environment-release-operations-assessment.md`](environment-release-operations-assessment.md)

## 0. 给 Claude Code 的直接指令

Claude Code 开始执行本规格时，应先完整阅读本文，然后按 Phase 0～6 顺序工作。

必须遵守：

1. 先检查工作区，不覆盖用户现有改动。
2. 先补测试/静态断言，再修改实现。
3. 本轮默认只修改仓库文件并执行本地测试、dry-run 和只读远端检查。
4. 未得到用户明确授权，不创建、修改或删除 Cloudflare、Polar、Apple、GitHub 远端资源。
5. 未得到用户明确授权，不执行任何 staging/production deploy、remote migration、secret put、webhook 修改或正式签名发布。
6. 不读取、打印或提交 secret。
7. 不运行 `xcodegen generate`。当前 [`project.yml`](../project.yml) 与实际 Xcode 工程有漂移。
8. 不修改 macOS Bundle ID、App Group、XPC Mach service、系统扩展 ID 和 entitlements；方案 A 明确保持同一应用身份。
9. 每完成一个 Phase，运行该 Phase 的验收命令并报告结果；失败不得继续远端步骤。
10. 所有生产写操作必须有二次保护，不能仅凭 `environment=production` 就执行。

若真实 ID、token、checkout URL、D1 ID 或签名资料缺失：

- 不猜测。
- 不填伪造值冒充完成。
- 保留明确的 `REQUIRED_*` 占位。
- 让 preflight 失败并列出缺失项。
- 继续完成不依赖这些值的代码、测试和文档。

## 1. 目标和完成定义

### 1.1 目标

在同一 monorepo 内建立可重复、可审计的 staging/production 发布接口：

- 两套官网入口。
- 两套 License API Worker。
- 两套 D1。
- 两套 Worker secrets。
- Polar sandbox/live 分离。
- 两套 Sparkle/DMG 更新域。
- macOS App 通过构建变量连接对应环境。
- staging 和 production 使用同一套脚本和同一个 Git commit，通过环境参数选择目标。
- 开发命令与运维命令分离。

### 1.2 不在本次范围

- 不创建可同时安装的独立 Staging macOS App。
- 不新增 staging Bundle ID、App Group、XPC service 或 provisioning profiles。
- 不迁移到 R2；DMG 小于 25 MiB 时继续使用 Workers Static Assets。
- 不拆分 Git 仓库。
- 不更换支付平台。
- 不重构 License 业务逻辑。
- 不修复与环境发布无关的 UI、代理或授权功能。
- 不自动启用 production CD。

### 1.3 完成定义

仓库层完成：

- 环境拓扑不再冲突。
- 有单一、可发现的 ops CLI。
- 所有公开环境配置有明确 schema 和校验。
- production 缺真实资源时会 fail closed。
- 原生发布不再重写 [`Config/AppConfig.xcconfig`](../Config/AppConfig.xcconfig)。
- 原生归档不再自动修改 tracked `project.pbxproj`。
- staging/prod 更新 feed 分离。
- 本地与 CI 可执行 dry-run。
- 所有脚本无 `/Users/admin` 等个人绝对路径。
- 有部署、验证、回滚和人工闸门说明。

远端完成必须由用户另行授权，并满足：

- production D1 已创建且三条 migration 全部应用。
- production Worker secrets 已注入。
- production Polar IDs 和 webhook 已配置。
- staging 全链路 smoke 通过。
- production 发布前人工审批通过。

## 2. 固定架构决策

### 2.1 域名

| 组件 | Staging | Production |
|---|---|---|
| Web | `https://staging.appidge.com` | `https://appidge.com`、`https://www.appidge.com` |
| API | `https://api-staging.appidge.com` | `https://api.appidge.com` |
| Updates | `https://updates-staging.appidge.com` | `https://updates.appidge.com` |
| App 内购买入口 | `https://staging.appidge.com/pricing` | `https://appidge.com/pricing` |
| Polar | Sandbox | Live |

不要改成 `api.staging.appidge.com` 等新命名；本方案优先复用仓库已有域名，减少改动。

### 2.2 Cloudflare 资源

Wrangler environments 会形成独立 Worker deployment：

| 组件 | Staging | Production |
|---|---|---|
| Web Worker | `appidge-web-staging` | `appidge-web-production` |
| API Worker | `appidge-api-staging` | `appidge-api-production` |
| Updates Worker | `appidge-updates-staging` | `appidge-updates-production` |
| D1 | `appidge-licensing-staging` | `appidge-licensing-production` |

目标共 6 个 Worker、2 个 D1，符合 Cloudflare Free 当前资源数量限制。

### 2.3 Cloudflare Free 保护线

实现 preflight 时固化以下保护：

- 动态 Worker 请求：账户合计 100,000 次/日。
- D1：账户合计 5,000,000 rows read/日、100,000 rows written/日、5 GB。
- D1 Free：最多 10 个数据库，单库最大 500 MB。
- Static Assets：Free 每个 Worker version 最多 20,000 文件。
- Static Assets：单文件最大 25 MiB。

参考：

- [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
- [D1 limits](https://developers.cloudflare.com/d1/platform/limits/)
- [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/)
- [Workers Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)

`publish-updates` 必须在上传前检查每个静态文件不超过 25 MiB；超过时拒绝部署并提示迁移 DMG 到 R2，不能静默跳过。

### 2.4 macOS 身份

staging/prod 继续共用：

- `com.appidge.app`
- `com.appidge.app.ProxyExtension`
- `group.com.appidge`
- `group.com.appidge.xpc`
- Developer ID 和 provisioning profiles
- Sparkle EdDSA 公钥

因此必须在运维文档和 CLI 输出中明确：

- 两个 App 不能安全并存。
- Staging 安装可能覆盖 Production。
- 只能在内部测试 Mac 使用 staging build。
- staging/prod 共用一个全局单调递增的 `CFBundleVersion` 序列。
- production build number 必须高于此前发布到任一 feed 的最高 build number。

## 3. 当前基线与已知问题

Claude Code 不应重复探索已经明确的事实，但要在修改前用只读命令确认：

### 3.1 已就绪

- [`apps/web/wrangler.jsonc`](../apps/web/wrangler.jsonc) 已有 staging/prod Web routes。
- [`apps/api/wrangler.toml`](../apps/api/wrangler.toml) 已有 staging route、Polar sandbox IDs 和 staging D1 ID。
- staging API 已设置 `MOCK_MODE=false`。
- Web 已支持四个 `PUBLIC_*` 构建变量。
- App 已支持 `LICENSE_API_BASE_URL`、`LICENSE_CHECKOUT_URL`、`SPARKLE_FEED_URL` build settings。
- App 已有真实 Sparkle 公钥。
- API 已有 `0001`、`0002`、`0003` 三条 migration。

### 3.2 必须处理

- [`infra/updates/wrangler.jsonc`](../infra/updates/wrangler.jsonc) 的 staging/prod 都占用 `updates.appidge.com`。
- API production 没有 `api.appidge.com` route。
- API production Polar IDs 和 D1 ID 仍是占位。
- [`scripts/release-staging.sh`](../scripts/release-staging.sh)：
  - 硬编码个人绝对路径。
  - 直接改写 tracked `Config/AppConfig.xcconfig`。
  - staging feed 仍指向 production updates 域。
  - App 购买入口直连 Polar sandbox，而不是 staging 官网。
  - 脚本名称看似发布全栈，实际只发布 App/updates。
- [`scripts/finish-release-staging.sh`](../scripts/finish-release-staging.sh) 有同类问题。
- [`scripts/archive-and-notarize.sh`](../scripts/archive-and-notarize.sh)：
  - 直接修改 tracked `project.pbxproj` 自增 build。
  - 只显式注入 License API/checkout，没有显式注入 Sparkle feed。
- [`scripts/verify-staging-update.sh`](../scripts/verify-staging-update.sh) 硬编码个人仓库路径和固定 feed。
- 现有 CI 只检查，不部署。

## 4. 目标文件结构

实现时新增：

```text
ops/
├── README.md
├── bin/
│   └── appidge-ops
├── environments/
│   ├── staging.conf
│   └── production.conf
├── lib/
│   └── common.sh
└── tests/
    └── test-config.sh
```

职责：

- `ops/environments/*.conf`：只保存可公开、可提交的构建配置，不保存 secret。
- `ops/lib/common.sh`：仓库根定位、配置读取、占位校验、URL 校验、生产保护、命令依赖检查。
- `ops/bin/appidge-ops`：单一运维入口。
- `ops/tests/test-config.sh`：无网络测试环境矩阵和安全保护。
- `ops/README.md`：给人执行的短 runbook；本文仍是给 Claude Code 的实施规格。

不要创建多个彼此复制命令的大型 deploy 脚本。所有部署逻辑应由 `appidge-ops` 调用，旧脚本只做兼容 wrapper。

## 5. 环境配置契约

### 5.1 `ops/environments/staging.conf`

仅包含以下非秘密值：

```sh
APPIDGE_ENVIRONMENT='staging'

PUBLIC_SITE_URL='https://staging.appidge.com'
PUBLIC_POLAR_CHECKOUT_URL='REQUIRED_POLAR_SANDBOX_CHECKOUT_URL'
PUBLIC_API_BASE_URL='https://api-staging.appidge.com'
PUBLIC_DOWNLOAD_URL='https://updates-staging.appidge.com/appidge-latest.dmg'

LICENSE_API_BASE_URL='https://api-staging.appidge.com'
LICENSE_CHECKOUT_URL='https://staging.appidge.com/pricing'
SPARKLE_FEED_URL='https://updates-staging.appidge.com/appcast.xml'

API_D1_DATABASE_NAME='appidge-licensing-staging'
```

若仓库已有经过验证的 Polar sandbox checkout URL，可以在确认它是公开链接后填入；否则保留 `REQUIRED_*`，让 Web build/deploy preflight 失败。

### 5.2 `ops/environments/production.conf`

```sh
APPIDGE_ENVIRONMENT='production'

PUBLIC_SITE_URL='https://appidge.com'
PUBLIC_POLAR_CHECKOUT_URL='REQUIRED_POLAR_LIVE_CHECKOUT_URL'
PUBLIC_API_BASE_URL='https://api.appidge.com'
PUBLIC_DOWNLOAD_URL='https://updates.appidge.com/appidge-latest.dmg'

LICENSE_API_BASE_URL='https://api.appidge.com'
LICENSE_CHECKOUT_URL='https://appidge.com/pricing'
SPARKLE_FEED_URL='https://updates.appidge.com/appcast.xml'

API_D1_DATABASE_NAME='appidge-licensing-production'
```

### 5.3 配置规则

- 文件必须可被 POSIX `sh` source。
- 只允许上述 allowlist keys。
- 所有 URL 必须是 HTTPS。
- staging URL 必须包含明确的 staging hostname。
- production URL 不得包含 `staging`、`sandbox`、`localhost`、`.invalid` 或 `PLACEHOLDER`。
- checkout URL 不得是 API token。
- `REQUIRED_*`、`PLACEHOLDER`、全零 UUID 必须触发 preflight 失败。
- 环境参数与配置内 `APPIDGE_ENVIRONMENT` 不一致必须失败。
- 不从根 `.env` 读取 Cloudflare/Polar secrets。
- 不把 Worker secret 名称以外的值写进日志。

## 6. `appidge-ops` 命令设计

统一接口：

```text
ops/bin/appidge-ops <command> <staging|production> [options]
```

必须实现以下命令：

```text
show-config
preflight
test
plan
migrate-api
deploy-api
deploy-web
build-macos
prepare-updates
publish-updates
smoke
release-manifest
```

### 6.1 通用选项

```text
--remote       执行需要登录的只读远端检查
--apply        允许远端写操作
--confirm-production
--build-number <positive integer>
```

规则：

- 没有 `--apply` 时，任何远端写命令只打印计划，不修改远端。
- staging 写操作要求显式 `--apply`。
- production 写操作同时要求：
  - `--apply`
  - `--confirm-production`
  - 环境变量 `APPIDGE_PRODUCTION_APPROVED=YES`
- 缺任一条件都必须 fail closed。
- CLI 默认不得从交互式输入读取 secret。
- 命令输出必须展示 environment、Git SHA、目标 hostname、D1 name；不得展示 secret。

### 6.2 `show-config`

输出脱敏后的公开配置和来源文件。

必须隐藏：

- 根 `.env` 内容。
- `.dev.vars` 内容。
- Worker secret 值。
- Apple 公证凭证。

### 6.3 `preflight`

本地 preflight：

- 检查工作区状态并打印，不自动要求 clean；涉及 release 时才要求无非预期改动。
- 校验环境配置 allowlist。
- 校验 URL 和环境匹配。
- 校验 Wrangler routes 与环境配置一致。
- 校验 staging/prod updates host 不重复。
- 校验 API production route 存在。
- 校验 production Wrangler 非秘密 IDs/D1 ID 不含占位。
- 校验 Node/pnpm/Wrangler。
- `build-macos` 前额外校验 Xcode、Signing config、profiles、notary auth、Sparkle tools。
- `publish-updates` 前校验 appcast、DMG、latest alias 和 25 MiB 文件限制。

`--remote` 只读检查：

- `wrangler whoami`。
- secret names 是否包含：
  - `POLAR_ACCESS_TOKEN`
  - `POLAR_WEBHOOK_SECRET`
  - `LICENSE_HMAC_PEPPER`
- D1 是否存在。
- pending migrations。
- 当前 Worker deployments/route 可查询。

不得读取 secret value。

### 6.4 `test`

运行环境配置测试和 dry-run，不执行远端写：

```text
ops/tests/test-config.sh
pnpm check
pnpm check:swift
wrangler deploy --dry-run --env <env>
```

原生签名构建只有在本机凭证齐全时运行；缺凭证应报告明确的 `SKIP`，不能假装成功。

### 6.5 `plan`

打印有序发布计划：

```text
environment
Git SHA
routes
D1
pending migrations
Web public config
macOS public config
expected artifact paths
smoke URLs
production guards
```

不得修改文件或远端。

### 6.6 `migrate-api`

计划/执行：

```sh
cd apps/api
pnpm exec wrangler d1 migrations list \
  "$API_D1_DATABASE_NAME" \
  --remote \
  --env "$APPIDGE_ENVIRONMENT"

pnpm exec wrangler d1 migrations apply \
  "$API_D1_DATABASE_NAME" \
  --remote \
  --env "$APPIDGE_ENVIRONMENT"
```

要求：

- 无 `--apply` 只 list，不 apply。
- apply 前重新显示 pending migration 文件。
- production apply 必须通过三重保护。
- migration 失败后禁止继续 API deploy。
- 不实现向下 migration；回滚使用补偿 migration。

### 6.7 `deploy-api`

执行前：

- `preflight`。
- `pnpm --filter api test`。
- production 检查真实 Polar IDs、D1 ID 和 secret names。

dry-run：

```sh
cd apps/api
pnpm exec wrangler deploy --dry-run --env "$APPIDGE_ENVIRONMENT"
```

远端：

```sh
cd apps/api
pnpm exec wrangler deploy --env "$APPIDGE_ENVIRONMENT"
```

部署后调用对应 `/healthz`，并记录 Cloudflare deployment 输出。

### 6.8 `deploy-web`

构建时显式注入：

```sh
PUBLIC_SITE_URL="$PUBLIC_SITE_URL"
PUBLIC_POLAR_CHECKOUT_URL="$PUBLIC_POLAR_CHECKOUT_URL"
PUBLIC_API_BASE_URL="$PUBLIC_API_BASE_URL"
PUBLIC_DOWNLOAD_URL="$PUBLIC_DOWNLOAD_URL"
```

步骤：

1. `pnpm --filter web typecheck`
2. `pnpm --filter web test`
3. `pnpm --filter web build`
4. 检查 `dist` 不含另一环境 hostname。
5. 检查 checkout/download CTA。
6. 无 `--apply` 只做 build 和 Wrangler dry-run。
7. 有 `--apply` 才执行 `wrangler deploy --env <env>`。

不要依赖 `apps/web/.env` 作为发布配置；发布必须显式来自 `ops/environments/*.conf`。

### 6.9 `build-macos`

必须要求：

```text
--build-number <positive integer>
```

并导出：

```sh
APPIDGE_BUILD_NUMBER='<argument>'
LICENSE_API_BASE_URL='<environment config>'
LICENSE_CHECKOUT_URL='<environment config>'
SPARKLE_FEED_URL='<environment config>'
```

然后调用：

```sh
scripts/archive-and-notarize.sh
scripts/make-dmg.sh
```

要求：

- 不修改 `Config/AppConfig.xcconfig`。
- 不修改 `project.pbxproj`。
- 不自动提交 build number。
- 构建前后比较这两个文件 hash；发生变化即失败。
- 归档后用 `PlistBuddy`/`defaults` 校验 App 内三个 URL 和 build number。
- staging build 明确打印“会覆盖 production 安装”警告。
- production build number 必须由操作者确认高于两个 feed 的最高历史版本；若无法查询 feed，production preflight 失败。

### 6.10 `prepare-updates`

步骤：

1. 从本环境最新 DMG 创建独立目录：

   ```text
   build/releases/<environment>/<version>-<build>/
   ```

2. 找到 Sparkle `generate_appcast`，不得硬编码 DerivedData hash。
3. 使用环境对应 updates base 生成 appcast。
4. 生成 `appidge-latest.dmg`。
5. 检查：
   - appcast enclosure host 与目标环境一致。
   - build number 正确。
   - EdDSA signature 存在。
   - enclosure length 与 DMG 一致。
   - 每个文件小于等于 25 MiB。
6. 将待发布静态资源复制到 `infra/updates/public/`。

该命令只准备本地资源，不部署。

### 6.11 `publish-updates`

执行前必须：

- 再运行 `prepare-updates` 的全部一致性检查。
- 检查 `infra/updates/wrangler.jsonc` route。
- 检查 staging 不会指向 `updates.appidge.com`。
- 检查 production 不会指向 `updates-staging.appidge.com`。

无 `--apply`：

```sh
cd infra/updates
<wrangler> deploy --dry-run --env "$APPIDGE_ENVIRONMENT"
```

有 `--apply` 才发布。

发布顺序应保证：

1. 版本 DMG 准备完成。
2. `appidge-latest.dmg` 准备完成。
3. appcast 校验完成。
4. 整个静态资源版本一次部署。

### 6.12 `smoke`

Web：

- 首页 200。
- `/pricing` 200。
- `/download` 200。
- 页面 canonical 属于目标环境。
- checkout URL 属于 Polar sandbox/live 预期。
- download URL 属于目标 updates host。

API：

- `/healthz` 200。
- `mockMode=false`。
- staging 可以在用户提供 sandbox license 后执行 activate/validate/deactivate。
- production 默认只做 health；真实 license 写操作必须单独授权。

Updates：

- `appcast.xml` 200。
- `appidge-latest.dmg` HEAD 200。
- enclosure host 正确。
- appcast build number 与本次 manifest 一致。
- staging/prod feed 不交叉。

macOS：

- 调用参数化后的 update 验证脚本。
- 真机系统扩展/Sparkle 升级仍是人工闸门。

### 6.13 `release-manifest`

生成：

```text
build/releases/<environment>/<version>-<build>/release-manifest.json
```

至少包含：

```json
{
  "environment": "staging",
  "gitSha": "...",
  "marketingVersion": "...",
  "buildNumber": 64,
  "createdAt": "...",
  "webSiteUrl": "...",
  "apiBaseUrl": "...",
  "updatesBaseUrl": "...",
  "d1DatabaseName": "...",
  "migrations": ["0001_init.sql", "0002_polar.sql", "0003_refund_tombstones.sql"],
  "artifacts": [
    {
      "path": "...",
      "sha256": "..."
    }
  ]
}
```

不得包含 checkout token 以外的 secret；Polar Hosted Checkout 是公开 URL，但 manifest 中只需记录其 hostname，避免无意义扩散完整链接。

## 7. 逐文件实施任务

### Phase 0：保护工作区和建立失败测试

执行：

```sh
git status --short
git branch --show-current
git log -5 --oneline
```

注意当前已有未跟踪文档：

```text
docs/environment-release-operations-assessment.md
```

必须保留，不覆盖、不删除。

先创建 `ops/tests/test-config.sh`，断言当前状态中的以下问题会失败：

- staging/prod updates hostname 重复。
- API production route 缺失。
- production Polar IDs/D1 ID 是占位。
- release scripts 含 `/Users/admin`。
- release script会改写 `AppConfig.xcconfig`。
- archive script含 `sed -i` 修改 `CURRENT_PROJECT_VERSION`。

测试要区分：

- “仓库结构实现缺失”——实现后必须转绿。
- “真实 production 资源缺失”——保留为 preflight 预期失败，直到用户填入真实值。

### Phase 1：环境拓扑和配置

修改 [`infra/updates/wrangler.jsonc`](../infra/updates/wrangler.jsonc)：

- staging route → `updates-staging.appidge.com`
- production route保持 `updates.appidge.com`
- 更新注释，不再描述两者冲突。

修改 [`apps/api/wrangler.toml`](../apps/api/wrangler.toml)：

```toml
[env.production]
workers_dev = false

[[env.production.routes]]
pattern = "api.appidge.com"
custom_domain = true
```

同时把 production D1 的非秘密名称统一为：

```toml
database_name = "appidge-licensing-production"
```

保留 production Polar IDs 和 D1 `database_id` 占位，除非用户提供真实值。

不修改 [`apps/web/wrangler.jsonc`](../apps/web/wrangler.jsonc) 的域名，只补必要注释或测试。

创建：

- `ops/environments/staging.conf`
- `ops/environments/production.conf`
- `ops/lib/common.sh`
- `ops/tests/test-config.sh`

同步当前架构文档，避免 Claude Code 后续继续按旧拓扑工作：

- [`infra/cloudflare/README.md`](../infra/cloudflare/README.md)：Workers Static Assets、双环境域名、`MOCK_MODE=false` staging、三条 migration。
- [`docs/sparkle-autoupdate.md`](sparkle-autoupdate.md)：当前 Updates 使用 Workers Static Assets，DMG 超过 25 MiB 才迁 R2。
- [`CLAUDE.md`](../CLAUDE.md)：只修正当前线上拓扑和发布入口，不重写历史开发协议。
- [`docs/commercialization-status.md`](commercialization-status.md) 和 [`docs/qa-evidence.md`](qa-evidence.md)：若保留历史内容，在顶部明确标记为历史证据，并链接新的 `ops/README.md`；不要把历史勾选改写成未经验证的线上状态。

验收：

- routes 不冲突。
- config tests 能识别 placeholder。
- staging 配置除了可能缺 checkout URL外结构通过。
- production preflight 明确列出真实资源缺口。

### Phase 2：原生构建去副作用

修改 [`scripts/archive-and-notarize.sh`](../scripts/archive-and-notarize.sh)：

1. 新增 `SPARKLE_FEED_URL`，production default 为：

   ```text
   https://updates.appidge.com/appcast.xml
   ```

2. 对三个 URL 做 HTTPS 和目标环境校验。
3. 要求 `APPIDGE_BUILD_NUMBER` 为正整数。
4. 删除从 pbxproj读取后 `sed -i` 自增的逻辑。
5. `xcodebuild archive` 显式传入：

   ```text
   CURRENT_PROJECT_VERSION
   LICENSE_API_BASE_URL
   LICENSE_CHECKOUT_URL
   SPARKLE_FEED_URL
   ```

6. 构建前后确认 tracked config 未变化。

修改 [`scripts/release-staging.sh`](../scripts/release-staging.sh)：

- 移除绝对路径。
- 移除 AppConfig 重写。
- 移除硬编码 Polar checkout。
- 作为兼容 wrapper 调用 `ops/bin/appidge-ops`。
- 无参数运行时显示新用法并退出非零，避免误发布。

修改 [`scripts/finish-release-staging.sh`](../scripts/finish-release-staging.sh)：

- 作为兼容 wrapper 指向 `prepare-updates`/`publish-updates`。
- 必须显式带 `--apply` 才发布。

修改 [`scripts/verify-staging-update.sh`](../scripts/verify-staging-update.sh)：

- 支持通过参数或环境变量传入 App path、feed URL、repo/build path。
- 默认仍可保持 staging，但默认 feed必须是 `updates-staging.appidge.com`。
- 不出现 `/Users/admin`。

验收：

```sh
sh -n scripts/archive-and-notarize.sh
sh -n scripts/release-staging.sh
sh -n scripts/finish-release-staging.sh
sh -n scripts/verify-staging-update.sh
```

并断言：

- `git diff` 不含自动生成的 build number 变化。
- `rg '/Users/admin' scripts` 不命中本次涉及脚本。
- `rg 'cat > .*AppConfig.xcconfig' scripts/release-staging.sh scripts/finish-release-staging.sh` 不命中。
- `rg 'sed -i.*CURRENT_PROJECT_VERSION' scripts/archive-and-notarize.sh` 不命中。

### Phase 3：实现 ops CLI

创建：

- `ops/bin/appidge-ops`
- `ops/README.md`

要求：

- POSIX `sh`，兼容 macOS `/bin/sh` 和 Ubuntu runner。
- 从脚本位置推导仓库根，不依赖执行 cwd。
- Wrangler 路径优先使用 workspace：

  ```text
  pnpm --dir apps/api exec wrangler
  ```

  不硬编码 `apps/api/node_modules/.bin`。

- 所有命令先调用公共配置校验。
- `--apply` 和 production 三重保护必须有自动测试。
- 默认输出 plan，不默认执行远端写。

### Phase 4：本地验证

运行：

```sh
ops/tests/test-config.sh
ops/bin/appidge-ops show-config staging
ops/bin/appidge-ops show-config production
ops/bin/appidge-ops preflight staging
ops/bin/appidge-ops preflight production
ops/bin/appidge-ops plan staging
ops/bin/appidge-ops plan production
pnpm check
pnpm check:swift
git diff --check
```

预期：

- staging preflight 只允许因真实 checkout/远端 secrets等人工输入失败，不能因代码结构失败。
- production preflight 应因真实 Polar IDs、D1 ID、checkout 或 secrets 缺失而 fail closed。
- 所有失败都要逐项列出，而不是只显示第一个。
- `plan` 不产生 tracked 文件变化。

Wrangler dry-run：

```sh
cd apps/api
pnpm exec wrangler deploy --dry-run --env staging
pnpm exec wrangler deploy --dry-run --env production

cd ../web
PUBLIC_SITE_URL=https://staging.appidge.com \
PUBLIC_POLAR_CHECKOUT_URL=https://checkout.example.invalid/staging-dry-run \
PUBLIC_API_BASE_URL=https://api-staging.appidge.com \
PUBLIC_DOWNLOAD_URL=https://updates-staging.appidge.com/appidge-latest.dmg \
pnpm build
```

注意：`.invalid` checkout 仅允许专用 test/dry-run fixture；实际 staging preflight/deploy 必须拒绝。

不要为了让 production dry-run通过而伪造 production ID。若 Wrangler 因占位失败，记录为人工闸门。

### Phase 5：Staging 远端人工闸门

只有用户明确授权后才执行。

#### Phase 5.1：Cloudflare staging

只读确认：

```sh
ops/bin/appidge-ops preflight staging --remote
```

确认：

- staging D1 存在。
- 三个 secret name 存在。
- `0001`～`0003` migration 状态。
- `updates-staging.appidge.com` 无冲突 DNS/CNAME。

写操作顺序：

```sh
ops/bin/appidge-ops migrate-api staging --apply
ops/bin/appidge-ops deploy-api staging --apply
ops/bin/appidge-ops deploy-web staging --apply
```

macOS：

```sh
ops/bin/appidge-ops build-macos staging --build-number <GLOBAL_NEXT_BUILD>
ops/bin/appidge-ops prepare-updates staging --build-number <GLOBAL_NEXT_BUILD>
ops/bin/appidge-ops publish-updates staging --apply --build-number <GLOBAL_NEXT_BUILD>
ops/bin/appidge-ops smoke staging
ops/bin/appidge-ops release-manifest staging --build-number <GLOBAL_NEXT_BUILD>
```

#### Phase 5.2：Staging 通过标准

- Web/API/updates 三个 hostname 均为 200。
- App Info.plist只含 staging API/site/feed。
- appcast 只含 staging updates URL。
- Polar sandbox 购买 → license → activate → validate 成功。
- sandbox refund/revoke → validate 返回 revoked。
- 旧 staging build → 新 staging build Sparkle 升级成功。
- 系统扩展升级后代理恢复。
- production hostname和 feed 未发生变化。

### Phase 6：Production 人工闸门

在 staging 完整通过之前禁止执行。

#### Phase 6.1：用户必须提供/确认

- production Polar organization ID。
- production Polar product ID。
- production Polar benefit ID。
- production Polar Hosted Checkout URL。
- production D1 ID。
- production Worker 三个 secret 已设置。
- Polar live webhook endpoint：

  ```text
  https://api.appidge.com/v1/webhooks/polar
  ```

- `updates.appidge.com` 已专属于 production Worker。
- production build number。
- production 发布审批。

#### Phase 6.2：Production 配置提交

真实非秘密 ID 可以提交到 `wrangler.toml`：

- organization ID
- product ID
- benefit ID
- D1 database ID

不得提交：

- Polar access token
- Polar webhook secret
- HMAC pepper
- Cloudflare API token
- Apple notarization secret
- Sparkle private key

#### Phase 6.3：Production 发布顺序

```sh
ops/bin/appidge-ops preflight production --remote
ops/bin/appidge-ops plan production
```

人工核对 plan 后：

```sh
APPIDGE_PRODUCTION_APPROVED=YES \
ops/bin/appidge-ops migrate-api production \
  --apply \
  --confirm-production

APPIDGE_PRODUCTION_APPROVED=YES \
ops/bin/appidge-ops deploy-api production \
  --apply \
  --confirm-production

APPIDGE_PRODUCTION_APPROVED=YES \
ops/bin/appidge-ops deploy-web production \
  --apply \
  --confirm-production
```

macOS 和 updates：

```sh
ops/bin/appidge-ops build-macos production \
  --build-number <GLOBAL_NEXT_BUILD>

ops/bin/appidge-ops prepare-updates production \
  --build-number <GLOBAL_NEXT_BUILD>

APPIDGE_PRODUCTION_APPROVED=YES \
ops/bin/appidge-ops publish-updates production \
  --apply \
  --confirm-production \
  --build-number <GLOBAL_NEXT_BUILD>

ops/bin/appidge-ops smoke production
ops/bin/appidge-ops release-manifest production \
  --build-number <GLOBAL_NEXT_BUILD>
```

## 8. CI/CD 分阶段策略

### 8.1 本次必须完成

- CLI 可在 CI 中运行 test/plan/dry-run。
- CI 不需要 Apple、Cloudflare、Polar production secrets也能验证仓库结构。
- production placeholder存在时 CI 应验证“preflight 正确拒绝”，不能把它当作异常红灯。

### 8.2 后续用户授权后再完成

可以新增一个手动 workflow：

```text
.github/workflows/deploy-cloudflare.yml
```

设计：

- `workflow_dispatch` 输入 `environment=staging|production`。
- job 使用同名 GitHub Environment。
- staging/production secrets 分开。
- workflow 只调用 `appidge-ops`，不复制部署逻辑。
- production GitHub Environment配置 required reviewers。
- workflow 记录 Git SHA 和 Wrangler deployment output。

第一版 workflow 只负责 API migration、API deploy 和 Web deploy。

macOS 签名、公证、Sparkle 私钥和 updates 发布继续留在受控 release Mac，直到密钥托管和 runner 策略单独评审完成。

不要在普通 PR CI 中注入 production secret。

## 9. 开发与运维边界

### 9.1 开发入口

保留：

```sh
pnpm dev:web
pnpm dev:api
pnpm check
pnpm check:swift
```

开发默认：

- API 使用 mock。
- 不需要 Cloudflare token。
- 不需要 production Polar secret。
- 不需要 notarization/Sparkle private key。

### 9.2 运维入口

所有环境动作统一从：

```text
ops/bin/appidge-ops
```

运维持有：

- Cloudflare deploy token。
- 环境 Worker secrets管理权限。
- Polar webhook/live配置权限。
- release Mac 和 Apple notarization凭证。
- Sparkle private key。

### 9.3 禁止交叉

- Web/API 开发脚本不读取根 Apple `.env`。
- 原生开发不读取 Cloudflare/Polar production secrets。
- ops 配置不导入业务源代码。
- migration文件仍由 API 开发负责，remote apply由运维负责。
- 任何 secret 不进入 `ops/environments/*.conf`。

## 10. 回滚设计

### 10.1 API

- 发布前记录当前 deployment ID。
- Worker 代码问题使用 Wrangler rollback或 Dashboard恢复上一 deployment。
- D1 不做 down migration；用新的补偿 migration 前滚。
- License API 是付费能力关键路径，回滚后立即跑 health和 validate smoke。

### 10.2 Web

- 发布前保存上一 Worker deployment ID。
- CTA/链接错误时恢复上一 Web deployment。
- 恢复后检查 canonical、checkout和 download URL。

### 10.3 Updates

- 每次 release manifest保存 appcast和 DMG SHA-256。
- 发布前保存上一 updates deployment ID。
- 错误 appcast优先恢复上一静态 deployment。
- 已被客户端下载的错误 macOS build不能依赖降低 build number修复；必须发布更高 build。

### 10.4 D1

- Free D1 当前 Time Travel窗口为 7 天。
- production migration前记录 bookmark/恢复信息。
- schema migration只增不改；破坏性 schema变更需要单独评审。

## 11. 安全与失败策略

Claude Code 实现时必须确保：

- 配置缺失：失败。
- 环境交叉：失败。
- production placeholder：失败。
- production 少任一确认：失败。
- staging/prod updates域相同：失败。
- 静态文件 >25 MiB：失败。
- appcast host错误：失败。
- build number非法或无法确认单调：失败。
- migration失败：停止后续部署。
- smoke失败：停止发布并输出回滚点。
- Git tracked config被 build修改：失败。
- secret疑似出现在 tracked diff：失败。

禁止：

- 自动把 `.env`、`.dev.vars`、Signing config加入 Git。
- 日志打印完整 license key。
- 日志打印 Polar/Cloudflare/Apple secret。
- 使用 `rm -rf` 指向仓库根、HOME或未校验变量。
- 默认 production。
- 为通过测试而把 production指向 sandbox。
- 为通过 preflight而使用全零/伪造 D1 ID。

## 12. 最终验收清单

### 12.1 仓库

- [ ] `git status` 中用户原有改动完整保留。
- [ ] `project.yml` 未被重生成。
- [ ] macOS identifiers/entitlements未修改。
- [ ] `ops/environments` 不含 secret。
- [ ] 所有个人绝对路径已从相关发布脚本移除。
- [ ] 发布构建不改 tracked AppConfig/pbxproj。
- [ ] staging/prod updates route不同。
- [ ] API production route存在。
- [ ] production placeholder被 preflight拒绝。

### 12.2 测试

- [ ] `ops/tests/test-config.sh` 通过。
- [ ] `pnpm check` 通过。
- [ ] `pnpm check:swift` 通过。
- [ ] 所有 shell `sh -n` 通过。
- [ ] staging API/Web/updates Wrangler dry-run通过。
- [ ] production dry-run若被真实资源阻塞，错误被记录为人工闸门。
- [ ] `git diff --check` 通过。
- [ ] 相对文档链接有效。

### 12.3 Staging

- [ ] `api-staging.appidge.com` 正常。
- [ ] `staging.appidge.com` 正常。
- [ ] `updates-staging.appidge.com` 正常。
- [ ] staging D1三条 migration已应用。
- [ ] Polar sandbox闭环通过。
- [ ] staging App三个公开 URL正确。
- [ ] Sparkle升级和系统扩展重绑通过。

### 12.4 Production

- [ ] production D1/Polar IDs已填真实值。
- [ ] production secrets names存在。
- [ ] live webhook已配置。
- [ ] production三重保护有效。
- [ ] staging release证据完整。
- [ ] production plan经人工审核。
- [ ] release manifest已生成。
- [ ] 回滚点已记录。

## 13. Claude Code 最终报告格式

Claude Code 完成仓库实现后，按以下格式报告：

```text
结果
- 完成了什么
- 没有执行哪些远端操作

变更
- 按文件/模块列出

环境状态
- staging：ready / blocked + 原因
- production：ready / blocked + 原因

验证
- 命令：PASS / FAIL / SKIP

人工闸门
- 缺少的真实 ID、secret、checkout、权限
- 用户下一步需要执行或授权的动作

安全确认
- 未提交 secret
- 未改 macOS identity
- 未运行 xcodegen
- 未进行未经授权的 deploy/migration
```

不得用“代码已完成”替代真实环境状态。仓库实现完成、远端资源就绪、正式发布完成必须分别报告。

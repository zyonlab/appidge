# Appidge

macOS 按进程透明代理：在系统网络层接管进程流量，按用户规则决定每个进程的每条连接走直连、上游代理（单台/代理链/故障转移/负载均衡）还是拦截。很多软件从不读 macOS 系统代理设置（自带网络栈的客户端、pip/npm/Go 工具链、Docker 等后台进程）——Appidge 让它们的流量也归你的规则管。

官网：<https://appidge.com> · 商业闭源，本仓库为私有 monorepo。

## 产品核心语义

- 全接管进程网络（Network Extension transparent proxy，非 TUN，不改路由表/DNS，崩溃 fail-open 不断网）。
- 按进程 + 目的地规则分流；配置过代理时默认走代理；较新的相同规则覆盖旧规则，即时生效。
- 活动页实时显示被接管进程与连接，点进程即可改规则。
- 自动识别并放行本地代理软件自身流量（防转发环）；检测到他方 TUN 虚拟网卡时警示冲突。
- 不提供节点：流量出口永远是用户自己配置的上游（Clash/Surge/xray 等本地端口或远程代理）。

## 仓库布局

```text
App/ Extension/ Packages/     macOS App、Network Extension、Swift packages（Core/IPCContract/EngineKit/AppFeature/ArchitectureTests）
appidge.xcodeproj project.yml XcodeGen 工程（改 project.yml 后 xcodegen generate）
apps/web                      Astro 静态官网（中/英）
apps/api                      Cloudflare Worker license facade + Creem webhook + D1
contracts/                    licensing.openapi.yaml（App ↔ Worker 唯一契约）+ 脱敏 fixtures
infra/cloudflare              D1 migrations 与部署说明
ops/                          环境矩阵（ops/environments/*.conf）与发布入口（ops/bin/appidge-ops），runbook 见 ops/README.md
scripts/                      签名、公证、DMG、扩展版本闸门
docs/                         设计与运营文档（见下）
```

## 本地开发

开发命令**不需要任何云凭证**：API 默认 mock，Web/API 开发不读 Apple 签名 `.env`，原生构建不读 Cloudflare/Creem secret。

```bash
pnpm install --frozen-lockfile   # Web/API workspace
pnpm dev:web                     # Astro 官网 dev server
pnpm dev:api                     # wrangler dev（默认 MOCK_MODE=true，不触真实 Creem）
pnpm check                       # lint + typecheck + test + build（web/api）
pnpm check:swift                 # 五个 Swift package tests
xcodebuild -project appidge.xcodeproj -scheme App -configuration Debug build
```

macOS 工程由 XcodeGen 生成：改了 `project.yml` 或增删源文件后跑 `xcodegen generate` 并提交 `project.pbxproj`。普通 Debug build 不需要签名配置；做签名/公证构建才需要根 `.env`（模板 `.env.example`）+ `./scripts/gen-signing-xcconfig.sh`。

质量闸门：Swift 6 并发零 warning、SwiftLint strict、五包测试全绿、`pnpm check` 全绿；TDD 约定与完整闸门见 `CLAUDE.md`。

## 环境与发布

双环境全部跑在 Cloudflare Free；矩阵单一真相源 `ops/environments/*.conf`，发布唯一入口 `ops/bin/appidge-ops`（详细 runbook：`ops/README.md`）。

| 组件 | Staging | Production |
|---|---|---|
| Web | staging.appidge.com | appidge.com / www |
| API | api-staging.appidge.com（Creem test） | api.appidge.com（Creem live） |
| Updates | updates-staging.appidge.com | updates.appidge.com |
| D1 | appidge-licensing-staging | appidge-licensing-production |

```bash
ops/bin/appidge-ops preflight staging          # 本地校验（--remote 加只读远端检查）
ops/bin/appidge-ops plan production            # 打印发布计划，不改任何东西
ops/bin/appidge-ops release staging --apply --build-number <N>   # staging 一键发布（fail-fast）
```

- **production 三重保护**：每个远端写命令须同时带 `--apply` + `--confirm-production` + 环境变量 `APPIDGE_PRODUCTION_APPROVED=YES`，缺一 fail-closed；解锁前提清单见 `docs/prod-launch-checklist.md`。
- **build 号**是 staging/production 共用的全局单调序列，`build-macos` 会拉两个 feed 校验；首发 feed 不存在时用一次性开关 `APPIDGE_ALLOW_MISSING_FEED=YES` 放行。
- **系统扩展版本与 app build 解耦**：没改 `Extension/`、`EngineKit`、`IPCContract` 就不 bump；改了必须在 `project.yml` bump `APPIDGE_EXT_BUILD_NUMBER` 并跑 `scripts/check-extension-version.sh --update`，出包闸门对两个方向硬失败。
- **回滚**：Worker 用 `wrangler rollback`/Dashboard 恢复上一 deployment；D1 只前滚（补偿 migration）；macOS 错误包只能发更高 build 修复，不能降号。
- macOS staging/production 共用 Bundle ID 与签名身份，两个包**不能并存**，staging 包只装内部测试机。

## 环境变量

| 位置 | 变量 | 性质 |
|---|---|---|
| `apps/web/.env` | `PUBLIC_SITE_URL` / `PUBLIC_POLAR_CHECKOUT_URL`（历史名，值为 **Creem** 支付链接） / `PUBLIC_API_BASE_URL` / `PUBLIC_DOWNLOAD_URL` | 构建期公开，进静态产物；缺失即 build 失败 |
| `apps/api/.dev.vars`（本地，模板 `.dev.vars.example`） | `MOCK_MODE`、`CREEM_API_KEY`、`CREEM_API_BASE`、`CREEM_PRODUCT_ID`、`CREEM_WEBHOOK_SECRET`、`LICENSE_HMAC_PEPPER` | 本地 secret，git-ignored |
| Cloudflare（线上） | 同上三个 secret 用 `wrangler secret put <NAME> --env <env>` 注入；`MOCK_MODE`/`CREEM_API_BASE`/`CREEM_PRODUCT_ID` 是 `wrangler.toml [env.*.vars]` 公开值 | secret 只存 Worker binding |
| 根 `.env`（模板 `.env.example`） | `TEAM_ID`、`DEVELOPER_ID_APPLICATION`、`PROFILE_APP/EXT`、公证凭证（Apple ID + app 专用密码，或 ASC API key 三件套） | 签名/公证专用，git-ignored，只在 release Mac |
| `ops/environments/*.conf` | 域名、D1 名、公开 checkout 链接等 | 全部公开值，可提交，无 secret |

## 关键文档

| 文档 | 说明 |
| --- | --- |
| `CLAUDE.md` | 仓库总控：架构边界、并行协作协议、验收标准 |
| `docs/creem-integration.md` | **现行** Creem license 集成基线（2026-07 test 模式全链路实测） |
| `ops/README.md` | staging/production 双环境部署与发布 runbook |
| `docs/commercialization-status.md` | 商业化阶段历史证据存档（勾选为当时状态） |
| `docs/polar-integration.md` | ⚠️ 已废弃（Polar 方案，仅历史参考） |
| `docs/experience-playbook.md` | 开发经验手册：macOS 出包、NE 转发坑、Creem、Cloudflare 免费层（可迁移） |

## 秘密与安全边界

Creem API key、webhook secret、Cloudflare token、Apple/Sparkle 私钥一律不进源码/日志/git：Worker 用 secret binding（本地 `.dev.vars` git-ignored），macOS 签名走 `.env` + `scripts/gen-signing-xcconfig.sh`，客户端只调用 `api.appidge.com`，绝不直连持密上游。

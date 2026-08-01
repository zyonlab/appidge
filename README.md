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

## 常用命令

```bash
pnpm install --frozen-lockfile   # Web/API workspace
pnpm check                       # lint + typecheck + test + build（web/api）
pnpm check:swift                 # 五个 Swift package tests
xcodebuild -project appidge.xcodeproj -scheme App -configuration Debug build
```

质量闸门：Swift 六并发零 warning、SwiftLint strict、五包测试全绿、`pnpm check` 全绿；TDD 约定与更多闸门见 `CLAUDE.md`。

## 关键文档

| 文档 | 说明 |
| --- | --- |
| `CLAUDE.md` | 仓库总控：架构边界、并行协作协议、验收标准 |
| `docs/creem-integration.md` | **现行** Creem license 集成基线（2026-07 test 模式全链路实测） |
| `ops/README.md` | staging/production 双环境部署与发布 runbook |
| `docs/commercialization-status.md` | 商业化阶段历史证据存档（勾选为当时状态） |
| `docs/polar-integration.md` | ⚠️ 已废弃（Polar 方案，仅历史参考） |

## 秘密与安全边界

Creem API key、webhook secret、Cloudflare token、Apple/Sparkle 私钥一律不进源码/日志/git：Worker 用 secret binding（本地 `.dev.vars` git-ignored），macOS 签名走 `.env` + `scripts/gen-signing-xcconfig.sh`，客户端只调用 `api.appidge.com`，绝不直连持密上游。

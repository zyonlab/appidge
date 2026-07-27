# CLAUDE.md · Appidge 商业化 Monorepo 并行开发总控

你是本仓库的 lead engineer。收到一个简短目标后，负责调查、拆分、并行委派、集成、验证和交付；不要只给方案。显式用户指令优先于本文件，缺少真实凭证或必须由人完成的系统操作时，推进到可验证的最远边界，再准确报告人工闸门，禁止伪造成功。

本阶段目标是：**保持现有 macOS 透明代理稳定的前提下，将仓库渐进扩展成 polyglot monorepo，并完成官网、Creem 商业授权、退款事件闭环和 Sparkle 静态更新链路。**

---

## 1. 已知现状与不可破坏项

- 当前仓库已经是 Swift 单仓多包：`App/`、`Extension/`、`Packages/`、`appidge.xcodeproj`、`project.yml` 和现有发布脚本均已工作。
- `Packages/` 包含 Core、IPCContract、EngineKit、AppFeature、ArchitectureTests；依赖方向、Swift 6 并发隔离、单向数据流和 fail-open 行为必须保持。
- Network Extension、Developer ID 签名、公证、DMG 产物和系统扩展升级重绑已有真实实现。任何商业化改动都不能导致网络转发、loop 排除、活动进程、规则即时生效或系统扩展升级回归。
- 产品核心语义：全接管进程网络；按用户规则判断目的地；自动处理代理软件 loop；配置过代理时默认走代理；活动页显示当前接管进程；用户点击进程可立即修改访问规则；规则按时间倒排，较新的相同规则覆盖旧规则。
- `docs/creem-integration.md` 是当前 Creem 集成基线（含 2026-07 test 模式全链路实测结论）；`docs/polar-integration.md` 已废弃，只作历史参考。所有时效性 API 行为在实现前仍要以 docs.creem.io 官方文档和 test 模式实测为准。
- Sparkle 集成目前在 `feat/sparkle-autoupdate` 分支；该分支落后主线。只移植 Sparkle 专属改动或先 rebase 后解决冲突，**禁止整目录覆盖、禁止盲目合并旧分支**。
- 当前分支已移除过时的架构期 `AGENTS.md`、`CRITERIA.md`、`PROGRESS.md`。不要重新创建它们，也不要把它们作为开工依赖。
- 保留大写 `Packages/`。不要创建小写 `packages/`，默认 macOS 大小写不敏感文件系统会产生冲突。

### 明确不做

- 不把现有 macOS 工程搬到 `apps/macos`；这会无谓破坏 Xcode 相对路径、签名、公证和系统扩展 embed。
- 不使用 Bazel、Nx 或 Lerna；当前规模采用 pnpm workspace + Turborepo 即可。
- 不把 Creem API key、Webhook secret、Cloudflare token、Apple/Sparkle 私钥放进客户端、源码、日志或 git。
- 不在 v1 暴露公开自动退款接口，不让客户端直接调用 Creem 的密钥型 API。
- 不用 Worker 中转 DMG 大文件下载；更新包走 Pages 或 R2 自定义域名。
- 不借商业化改造重写已工作的路由/转发架构，不做无关重构或依赖升级。

---

## 2. 每次 session 开工顺序

1. 运行 `git status --short`、`git branch --show-current`、`git log -10 --oneline`；保护用户未提交改动，不 reset、不覆盖。
2. 读取本文件、`docs/creem-integration.md`、相关源码和现有 CI/发布脚本。不要凭记忆假设当前实现。
3. 只让需要某类秘密的 Agent 获得最小权限：
   - Web/API 纯开发不得读取 Apple 签名 `.env`。
   - macOS 构建需要 `.env` 时，只校验变量存在，不打印值，并运行 `./scripts/gen-signing-xcconfig.sh`。
   - Worker 本地秘密放 git-ignore 的 `.dev.vars`；线上用 `wrangler secret`。
4. 建立基线证据：
   - Swift 改动前至少跑相关 package tests；涉及 App/Extension/Xcode 工程时跑完整 Swift tests 和 Debug build。
   - Web workspace 建立后跑 `pnpm install --frozen-lockfile` 与现有 `pnpm check`。
5. 为本轮任务写一个短执行图，明确依赖、可并行项、Agent 文件所有权和验收命令；能推进就直接推进，不因非关键偏好停下来问。
6. 只有真实外部状态会被改变时才需要当前任务授权：生产部署、Creem 真实退款、提交真实订单、push/PR、密钥轮换。未授权时做到本地验证或 dry-run。

所有详细日志写入临时文件，聊天和 Agent 汇报只保留结论、失败原因及最后几十行。严禁把 `.env`、profile 内容或 token 输出进日志。

---

## 3. 目标架构与仓库边界

采用渐进式 monorepo，Swift 根目录保持不动：

```text
appidge/
├── App/                         # 现有 macOS App，保持路径
├── Extension/                   # 现有 Network Extension
├── Packages/                    # 现有 Swift packages
├── appidge.xcodeproj
├── project.yml
├── scripts/                     # 现有签名、公证、DMG；可增量添加 release 脚本
│
├── apps/
│   ├── web/                     # Astro 静态官网
│   └── api/                     # Cloudflare Worker (TypeScript)
├── contracts/
│   ├── licensing.openapi.yaml   # App ↔ Worker 唯一 API 契约
│   └── fixtures/                # 脱敏请求/响应/Webhook fixtures
├── infra/
│   └── cloudflare/              # D1 migrations、部署说明、非秘密配置
├── docs/
│   └── commercialization-status.md
├── package.json
├── pnpm-workspace.yaml
├── turbo.json
└── pnpm-lock.yaml
```

### 工具决策

- Node/package manager：pnpm，根 `package.json` 用 `packageManager` 锁定实际安装并验证过的版本。
- JS/TS orchestration：Turborepo，只编排 Web/API 的 `dev`、`lint`、`typecheck`、`test`、`build`。
- 官网：Astro 静态输出，不引入 SSR，不为简单营销页引入 React。
- Worker：TypeScript module Worker；四五个路由优先使用原生 `fetch` 路由和小型显式模块，避免无必要框架。
- API 契约：OpenAPI 是语言边界真相；Swift/TypeScript DTO 与 fixtures 做契约测试。初期不要为了少量 DTO 引入脆弱的跨语言代码生成。
- 缓存：启用 pnpm 与 Turbo 本地/CI 缓存；有安全 token 和明确收益后再启远端缓存。签名、公证、DMG、appcast 不进入通用缓存。
- CI affected detection：用 workflow path filters + Turbo filter。Web-only 改动不跑 macOS CI，Swift-only 改动不部署官网，但 main 的最终集成闸门必须能一次跑全。

### 线上拓扑（staging/production 双环境，全部 Cloudflare Workers，免费层）

```text
staging.appidge.com          appidge-web-staging      官网（Workers 静态资源）
appidge.com / www             appidge-web-production   官网（Workers 静态资源）
api-staging.appidge.com      appidge-api-staging      license facade + Creem test webhook
api.appidge.com              appidge-api-production   license facade + Creem live webhook
updates-staging.appidge.com  appidge-updates-staging  DMG/appcast（Workers 静态资源；>25MiB 才迁 R2）
updates.appidge.com          appidge-updates-production 同上，专属 production
D1 ×2                        appidge-licensing-staging / appidge-licensing-production
Creem 支付链接                staging=test 链接，production=live 链接；网站和 macOS App 直接打开
```

环境矩阵单一真相源：`ops/environments/*.conf`；部署/发布统一入口：`ops/bin/appidge-ops`
（preflight fail-closed + production 三重保护），runbook 见 `ops/README.md`。

Cloudflare 免费层是 MVP 目标，不是可靠性假设。App 必须缓存最近一次有效授权并提供可测试的离线宽限，不能因为 Worker/Creem 临时不可用而立即锁死付费用户。

---

## 4. 并行 Agent 协议

主 Agent 负责依赖图、契约、文件所有权、集成和最终验收；子 Agent 只处理有界任务。默认最多同时运行 3 个 worker，避免工作树和上下文失控。

### 隔离规则

- 优先为每个 Agent 创建独立 git worktree + 本地分支，例如 `feat/mono-workspace`、`feat/commerce-api`、`feat/website`、`feat/sparkle-release`、`feat/macos-license`。
- 若环境不能使用 worktree，则严格执行下面的独占目录；两个 Agent 不得同时编辑同一文件。
- 只有主 Agent 可以修改本 `CLAUDE.md`、更新总状态、合并/rebase 其他 Agent 的提交。
- 子 Agent 不得自行 merge main、push、开 PR、部署或操作真实 Creem 交易。
- 每个 Agent 完成时必须提交：commit hash、改动文件、测试命令与结果、未决风险；没有测试证据不算完成。
- Agent 遇到契约歧义先给主 Agent发一条最小问题，不得各自发明不兼容协议。

### Wave 0：主 Agent 串行打地基

- 建立当前基线并确认工作树。
- 从本文件固化 `contracts/licensing.openapi.yaml` 的 v1 轮廓和标准错误模型，避免 API 与 macOS 客户端各写一套。
- 确认 `feat/sparkle-autoupdate` 与当前分支的共同祖先和 Sparkle 专属改动范围。
- 记录 `docs/commercialization-status.md`，只由主 Agent更新勾选状态和证据。

### Wave 1：可并行

**Agent A · Workspace/CI**

- 独占：根 `package.json`、`pnpm-workspace.yaml`、`turbo.json`、`.github/workflows/`、Node 相关 ignore/config。
- 建立 pnpm/Turbo，不移动 Swift 文件。
- 将 CI 拆为 macOS 与 web/api 路径感知任务；保留现有 SwiftLint 和五个 Swift package tests。
- 不触碰 `App/`、`Extension/`、`appidge.xcodeproj`。

**Agent B · Website**

- 独占：`apps/web/`。
- 建 Astro 静态站：首页、功能、下载、定价、FAQ、退款政策、隐私、条款。
- 产品表达必须与第 1 节核心语义一致，不虚构测速、安全或兼容性声明。
- “购买”使用可配置的 Creem 支付链接；“下载”指向 `updates.appidge.com`。
- 默认无 cookie、无追踪、无 SSR；移动端、键盘导航、语义 HTML、对比度和 SEO 元数据必须达标。
- 法律文本明确标记需要用户最终审核，不冒充法律意见。

**Agent C · Worker/Creem**

- 独占：`apps/api/`、`contracts/`、`infra/cloudflare/`。
- 实现 license facade、Webhook 验签、D1 migration、测试 fixtures、Wrangler dev/dry-run。
- 只调用 Creem test API（`https://test-api.creem.io`，与生产完全隔离、key 独立）；没有 test secret 时用协议化 mock 跑完自动测试，并留下一个可执行、不会泄密的 sandbox smoke 脚本。
- 不部署生产，不执行真实退款。

**Agent D · Sparkle/Release**（若并发槽足够，否则在 A 完成后启动）

- 独占：Sparkle 所需的 `App/AppidgeApp.swift`、`App/Info.plist`、Xcode package reference、`Package.resolved`、相关发布脚本和 Sparkle 文档。
- 只移植旧分支 Sparkle 专属改动；不得带回旧 UI、旧本地化、旧 Extension 或删除主线文件。
- 本 Wave 运行期间不得启动其他会编辑 App/Xcode 工程的 Agent。

### Wave 1 集成顺序

主 Agent依次审查并集成 A → C → B → D。每次集成先 rebase 当前集成分支、解决冲突、跑该域测试；不得一次合并所有分支后再排查。

### Wave 2：契约稳定后

**Agent E · macOS License Client**

- 独占：`App/` 许可 UI/客户端、必要的 `Packages/Core`/`Packages/AppFeature` 状态与测试；开始前必须基于已集成 Sparkle 的最新分支。
- UI 只读 State、dispatch Action；网络与 Keychain 都走 Effect/协议注入，不能在 SwiftUI View 直接请求 API 或改共享状态。
- 不更改 EngineKit 转发路径，除非有失败测试能证明确有必要。

**Agent F · Integration/QA**

- 独占：跨端 contract tests、smoke scripts、`docs/commercialization-status.md` 的证据草稿；不直接重写业务实现。
- 验证 Creem test 模式、退款 Webhook、离线宽限、旧版本 Sparkle 升级、网站链接和 Cloudflare dry-run。
- 发现缺陷先写最小复现测试，再交回对应 owner 修复。

Wave 2 中 E 与 F 可并行，但 F 不得编辑 E 正在修改的 Swift 文件。

---

## 5. 实现规格

### 5.1 Workspace 与 CI

根命令至少提供：

```text
pnpm dev:web
pnpm dev:api
pnpm lint
pnpm typecheck
pnpm test
pnpm build
pnpm check          # lint + typecheck + test + build
pnpm check:swift    # 只包装可重复的 Swift package tests，不缓存签名产物
```

- 提交 lockfile；CI 必须使用 frozen lockfile。
- Turbo output/cache 路径必须准确，不能缓存 `.env`、`.dev.vars`、签名物料或 Xcode DerivedData。
- macOS CI 继续选择 Swift 6 toolchain并运行 Core、IPCContract、EngineKit、AppFeature、ArchitectureTests。
- 发布工作流与普通 CI 分开；公证和生产部署只允许手动触发且需要受保护 secrets。

### 5.2 官网

至少提供以下静态路由：

```text
/
/download
/pricing
/faq
/refund
/privacy
/terms
```

- 首页首屏应在一句话内说明“按进程控制网络去向”，随后解释全接管、目标地规则、loop 自动排除、活动进程即时改规则、最新规则覆盖。
- CTA 分为“下载试用/下载 App”和“购买许可证”，不要把购买与下载混成一个不可逆操作。
- Creem 支付链接、API base URL、下载 URL 使用构建期公开配置并校验，缺失时 build 失败，不偷偷使用错误生产地址。
- ⚠️ 官网侧支付链接的环境变量名仍叫 `PUBLIC_POLAR_CHECKOUT_URL`（Polar 时期遗留），**值是 Creem 支付链接**。这是已登记的技术债（`docs/creem-integration.md §8`），改名牵动 `apps/web` 构建与 `check-site`——不要顺手改名，要改就整条链路一起改。
- 站点所有内部链接和公开资源在 CI 做链接检查；生成 sitemap、robots、Open Graph 和基础 structured data。
- 当前 DMG 较小，但产物域名仍固定为 `updates.appidge.com`，避免未来超过 Pages 单文件限制时修改客户端。

### 5.3 Worker API 契约

公开路由限定为：

```text
GET  /healthz
POST /v1/licenses/activate
POST /v1/licenses/validate
POST /v1/licenses/deactivate
POST /v1/webhooks/creem
```

要求：

- `activate` 接收 `licenseKey`、`instanceName`、`appVersion`；标准化返回状态、`instanceId`、过期时间、激活数量/上限和 `validatedAt`。
- `validate` 接收 `licenseKey`、`instanceId`、`appVersion`；先查本地 revoked 状态，再调用 Creem。
- `deactivate` 接收 `licenseKey`、`instanceId`；成功后返回统一状态。
- 错误体稳定且不透传 Creem 内部响应：`invalid_request`、`invalid_license`、`activation_limit`、`expired`、`revoked`、`rate_limited`、`upstream_unavailable`、`internal_error`。
- 请求体大小、Content-Type、字段长度、product ID 都有白名单验证。此 Worker 不是通用 Creem 代理。
- API secret 只从 Worker secret binding 获取；任何响应、异常和日志都不能含 API key 或完整 license key。
- CORS 只是一项浏览器策略，不是桌面客户端鉴权；必须另做请求限速、输入约束和滥用保护。

### 5.4 Webhook、D1 与退款

- 验签是 **Creem 自己的方案，不是 Standard Webhooks**（Polar 时期的写法已废弃，别混）：头 `creem-signature` = `hex(HMAC-SHA256(secret, 原始请求字节))`，恒定时间比较；验签成功后才解析 JSON。secret 按 Dashboard **字面值**使用——`whsec_` 前缀不剥离、不 base64 解码。
- **没有 `webhook-id` / `webhook-timestamp` 头**，签名不含时间戳，无漂移窗口可校验；防重放只能靠 payload 顶层事件 ID（`id: "evt_..."`）在 `webhook_events` 的唯一约束幂等登记，重复投递返回成功但不重复执行副作用。
- 事件信封为 `{ id, eventType, created_at, object }`，业务字段在 `object` 下。payload 字段必须用 Creem test 模式捕获的脱敏 fixture 证明（`contracts/fixtures/creem/*.json` 已是 2026-07-21 真实捕获），禁止按文档猜字段名。
- `entitlements` 主键列名仍是 `license_key_id`（Polar 时期留下的历史名，未改名），值是 Creem LicenseEntity 的 `id`；`benefit_id` 列同为历史残留。保存 order/customer/product 标识、license HMAC fingerprint、状态和时间戳；默认不保存完整 license key、原始支付 payload 或不必要的 PII。
- 处理 `checkout.completed`（审计，**不含 license key**，不建 entitlement）、`refund.created` / `dispute.created`（order tombstone + 按 order 尽力吊销）；其余事件登记后安全忽略。product 白名单：`CREEM_PRODUCT_ID` 不匹配的事件登记后忽略。
- **吊销主路是 validate，不是 webhook**（2026-07-21/22 实测）：三种事件都不带 license key，且 license API 有 license 无 order，**无公共 join key**，无法用 webhook 精确吊销某个 license。且**退款不会自动 disable license**（真实退款后 validate 仍返回 active）。
- ⇒ 运营流程：退款/拒付时在 Creem Dashboard 处理退款的**同时手动 disable 该 license**，App 每日 validate 即锁定（disabled → facade `revoked`）。webhook 落库仅作审计/对账。这条人工步骤是硬依赖，漏做等于退款后用户仍可用。
- 本地 deny 优先于上游 active（`entitlements.status=revoked` → validate 直接返回 revoked）；运营可直接在 D1 写 revoked 作最后杠杆。不要凭邮箱或模糊字段吊销。

D1 至少有迁移和索引测试，包含：重复 webhook、乱序事件、退款先于本地 checkout 记录、未知 product、处理失败后的安全重试。

### 5.5 macOS 授权客户端

状态机至少覆盖：

```text
unlicensed → activating → licensed
licensed → validating → licensed
licensed/validating → gracePeriod → licensed | expired
licensed → deactivating → unlicensed
任何状态 → revoked / recoverableError
```

- license key、instance ID、上次成功校验时间进入 Keychain，不存明文 plist/UserDefaults。
- API base URL 由受控构建配置提供；生产客户端只调用 `api.appidge.com`，绝不直连带 `x-api-key` 的 Creem API。
- 激活实例名使用隐私友好且稳定的安装标识；不要默认把用户邮箱、真实主机名或硬件序列号发给服务端。
- 默认每日校验；网络/5xx 采用退避重试。离线宽限配置集中管理，默认 7 天并有边界测试。
- Worker/Creem 暂时不可用进入 grace，而不是立即 revoke；明确的 revoked/expired 才锁定付费能力。
- Keychain、时钟、API client 都是协议并可注入 mock；Core reducer 保持纯函数，Store 保持 `@MainActor`。
- “购买许可证”只打开支付链接（或官网定价页）；用户从确认邮件/客户门户复制 license key 回 App 激活。UI 文案不写死支付商名字（换 MoR 时不必改 UI 与译文）。v1 不做浏览器回跳自动灌 key。
- License UI 改动不能阻塞用户查看诊断/帮助，也不能因授权服务故障造成系统网络黑洞。

### 5.6 Sparkle 与发布

- 使用 Sparkle 2 的 `SPUStandardUpdaterController`；只加到 App target，Extension 不链接 Sparkle。
- `SUFeedURL=https://updates.appidge.com/appcast.xml`。
- `SUPublicEDKey` 必须来自真实 `generate_keys` 输出。私钥留在 Keychain或受保护 CI secret；若缺密钥，Agent只能给出准确命令并停在人工闸门，禁止提交 TODO 冒充完成。
- 优先使用官方 `generate_appcast` 自动生成 EdDSA 签名、长度、feed 和可选 delta；不要手工拼签名 XML，除非有明确测试理由。
- 发布顺序固定：

```text
archive-and-notarize.sh
→ make-dmg.sh
→ generate_appcast
→ 校验 codesign/notary/staple/appcast signature
→ 上传 DMG/appcast/release notes 到 R2
→ 从上一生产版本做真实更新 smoke test
```

- 上传使用独立脚本，可 dry-run，可重复执行；R2 对象使用不可变版本路径，`appcast.xml` 最后原子更新，避免 feed 指向未上传文件。
- 系统扩展升级必须复用现有 provider 版本握手与重绑逻辑；至少保留旧版 → 新版的人工 smoke 步骤。
- **系统扩展版本与 app build 号解耦**（升级黑洞的根本缓解）：扩展版本钉在 project.yml 的
  `APPIDGE_EXT_BUILD_NUMBER`/`APPIDGE_EXT_MARKETING_VERSION`，扩展内容（`Extension/`、EngineKit、
  IPCContract）没变就不 bump——系统跳过扩展替换，升级竞态窗口不打开。改了必须 bump 并跑
  `scripts/check-extension-version.sh --update`；出包闸门对两个方向硬失败（规则详见 `ops/README.md`）。
- 下载走 `updates.appidge.com` 直达 R2，不经过 license Worker。

---

## 6. TDD、安全和质量闸门

### TDD

- Core、AppFeature、Worker entitlement/webhook 逻辑必须先有失败测试再实现。
- Bug 修复必须先添加能复现的测试；UI 纯样式可用构建、快照/截图和可访问性检查作为证据。
- Mock 必须在协议边界，不得 mock 被测函数本身。自动测试不访问真实支付、生产 Worker、真实 NE 流量。

### Worker 必测

- 有效/无效 Webhook 签名、原始 body 改一字节即失败。
- webhook 重放幂等、乱序安全、未知事件安全忽略。
- activate/validate/deactivate 正常和 Creem 4xx/5xx/timeout 映射；未知/缺失 status 一律按 transient 进宽限，绝不误翻 revoked。
- refund/dispute 后本地 revoked 优先于上游 active。
- 日志脱敏，完整 license/API key 不出现。
- body 超限、错误 Content-Type、未知 product、畸形 JSON、限速路径。

### macOS 必测

- 授权状态机、Keychain 失败、首次激活、每日 validate、deactivate。
- 7 天 grace 的开始、最后一刻、超时边界和系统时间异常。
- 暂时网络失败不 revoke；明确 revoked/expired 会落入正确状态。
- 原有 Core/IPC/Engine/AppFeature/ArchitectureTests 全绿。
- 完整 Debug build 无 Swift 6 并发 warning；涉及 release 配置时再跑签名、公证检查。

### Website 必测

- production build、类型检查、内部链接、关键 CTA URL、404。
- 无 JS 时核心内容与购买/下载链接仍可用。
- 键盘操作、focus、语义 heading、对比度、窄屏布局。
- 页面不泄露私有 API 地址、secret 或测试 checkout。

---

## 7. Commit、集成与报告纪律

- 先确认 dirty worktree；现有修改归用户，不得删除、reset 或顺手格式化无关文件。
- 每个有意义的绿提交一个小 commit，message 说明域和结果。Agent只提交自己所有权范围。
- 每个 commit 前运行该域最小完整闸门；主 Agent最终集成后运行全量闸门。
- 不提交失败构建、占位密钥、真实支付 fixture、生成的签名配置、`.dev.vars`、Cloudflare state、DerivedData 或 build 产物。
- push/PR 以当次用户授权为准；未授权时只做本地 commits，并在最终报告列出 hash。
- Agent失败时记录：命令、精简错误、已验证原因、下一条不同路径。禁止原样重复同一失败尝试。
- 最终报告必须区分：已自动验证、只做静态检查、需要真实 secret、需要用户点击/审核、需要生产部署。

---

## 8. 总验收（Definition of Done）

以下全部满足，商业化 monorepo 阶段才算完成：

- [ ] 现有 Swift/Xcode 路径未移动；根 pnpm/Turbo workspace 可重复安装并全绿。
- [ ] CI 能按改动范围运行，main 集成闸门覆盖 Swift、Web、Worker。
- [ ] Astro 官网包含下载、购买、退款、隐私、条款页面并在 Cloudflare preview 验证。
- [ ] Hosted Checkout test flow 能完成购买并获得 license key。
- [ ] Worker license facade 不泄露 Creem API key，契约测试和错误映射全绿。
- [ ] Webhook HMAC、D1 幂等、refund/dispute revoke 有自动测试与 sandbox 证据。
- [ ] macOS App 用 Keychain 保存授权信息，activate/validate/deactivate 与 7 天 grace 全绿。
- [ ] Sparkle 公钥、feed、签名更新包和 R2 路径真实可验证，不含 TODO 私钥配置。
- [ ] 从上一版 App 到新版本的 Sparkle + 系统扩展升级 smoke test 有结果。
- [ ] `swift test` 五包全绿，SwiftLint strict 全绿，完整 App Debug build 成功。
- [ ] `pnpm check` 全绿，Worker dry-run/preview 成功，仓库 secret 扫描无泄漏。
- [ ] `docs/commercialization-status.md` 给出部署、回滚、密钥轮换、退款操作和剩余人工闸门。

若缺少 Creem/Cloudflare/Apple/Sparkle 真实凭证，代码和自动测试完成不等于上线完成；在状态文档中保持对应项未勾选，并给用户一条最短、可执行的解锁步骤。

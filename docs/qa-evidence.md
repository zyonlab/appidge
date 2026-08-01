# Appidge 商业化 · Integration/QA 证据（Agent F）

> ⚠️ **历史证据存档**（2026-07-21，Creem 时期 MOCK 运行）：仅作历史记录，不代表当前线上状态。
> 当前双环境发布/验证入口见 `ops/README.md`。

> 本文件是 Agent F（Integration/QA）的验收证据与人工闸门 runbook。
> `docs/commercialization-status.md` 的勾选状态由主 Agent 维护；本文件只提供可复现命令 + PASS/FAIL + 输出证据。
> 全程 **MOCK_MODE**，不触真实支付服务商 / 生产 Cloudflare / 真实支付 / 真实 NE 流量。

> **时效更正（2026-08-01）**：当时计划的「Creem → Polar 迁移」已于 2026-07-24 中止，license 后端
> **切回并保持 Creem**（现行基线 = `docs/creem-integration.md`）。本文记录的 Creem-based MOCK 运行
> 证据——环境变量名（`CREEM_API_KEY` / `CREEM_WEBHOOK_SECRET` / `CREEM_API_BASE` / `CREEM_PRODUCT_ID`）、
> 请求头（`creem-signature`）、上游端点（`test-api.creem.io`）、webhook 路由（`/v1/webhooks/creem`）、
> 事件名（`checkout.completed` / `refund.created`）、fixture 路径（`contracts/fixtures/creem/`）——
> 与 `apps/api` 现行实现一致，**证据继续有效**，原「TODO(polar) 待核实」不再适用。

- 分支：`feat/integration-qa`（基于 `feat/commercialization-monorepo` 尖端 `2061592`）
- 日期：2026-07-21
- 平台：macOS (darwin 25.6)；node v22.17.0；pnpm 10.13.1；wrangler 4.42.0；jq 1.7.1
- 新增文件（Agent F 所有权范围内）：
  - `scripts/smoke-license-mock.sh` — 本地 wrangler dev 上的 license facade 端到端 MOCK 冒烟
  - `scripts/qa-contract-check.sh` — 仓库根可发现入口，复用 apps/api ajv 契约测试
  - `docs/qa-evidence.md` — 本文件

**未触碰**：任何 Swift（`App/`、`Extension/`、`Packages/**`）、`apps/*/src/**`、`apps/*/test/**`、
`contracts/licensing.openapi.yaml`、`project.yml`、`appidge.xcodeproj/**`、`docs/commercialization-status.md`、
以及任何既有脚本。Agent E 并行编辑的 Swift 文件未被本 Agent 修改。

---

## Task 1 · 契约一致性（fixtures ↔ OpenAPI）— PASS

`contracts/fixtures/facade/*.json` 的 response 用 ajv（Ajv2020 + ajv-formats）对 `licensing.openapi.yaml`
的 `LicenseState` / `Error` / `DeactivateResponse` schema 校验。断言逻辑复用 apps/api 既有
`test/contract.test.ts`，不引入新 node 依赖。新增仓库根入口 `scripts/qa-contract-check.sh` 使其可发现。

命令：
```bash
scripts/qa-contract-check.sh          # 或：cd apps/api && pnpm run test:contract
```
结果：**PASS**（EXIT=0）。最后输出：
```
 ✓ |contract| test/contract.test.ts (6 tests) 4ms
 Test Files  1 passed (1)
      Tests  6 passed (6)
```
覆盖：activate.success / validate.revoked → 合法 LicenseState；error.activation_limit → 合法 Error；
DeactivateResponse 正负例；非法 LicenseState 被拒；Error 顶层无 enum、错误码集合与契约完全一致。

---

## Task 2 · MOCK 端到端 license 冒烟 — PASS

`scripts/smoke-license-mock.sh`：在临时持久化目录上 `wrangler d1 migrations apply --local` 建表，
后台起 `wrangler dev`(MOCK_MODE)，轮询 `/healthz` 就绪后依次打真实 HTTP：
activate → validate(active) → **已 HMAC 签名的** refund.created webhook → validate(**revoked**) →
篡改签名(401) → 无签名(401) → deactivate。webhook 签名用 `.dev.vars` 里同一 `CREEM_WEBHOOK_SECRET`
对**原始字节**做 HMAC-SHA256（node crypto），header `creem-signature`。脚本每次用唯一 license + 独立
临时 D1 目录，结束 kill 进程树并清理；缺 wrangler/jq/node/curl 时 SKIP。

命令：
```bash
scripts/smoke-license-mock.sh
```
结果：**PASS**（EXIT=0，17/17 断言）。完整输出：
```
· 已从 .dev.vars.example 复制出 .dev.vars（MOCK 占位值）
=== Appidge MOCK license 冒烟 ===
· license=MOCK-LICENSE-SMOKE-1784616776-82971  product=prod_PLACEHOLDER_xxxxxxxx  port=8798
· D1 迁移完成（0001_init.sql）
· wrangler dev 启动中 (pid=83001)…
  PASS  healthz status (.status=ok)
  PASS  healthz mockMode (.mockMode=true)
  PASS  activate 状态码 (HTTP 200)
  PASS  activate.status (.status=active)
  PASS  activate.activationLimit (.activationLimit=3)
  PASS  activate.instanceId=inst_MOCK_0000000000
  PASS  activate.validatedAt=2026-07-21T06:53:02Z
  PASS  validate(退款前) 状态码 (HTTP 200)
  PASS  validate(退款前).status (.status=active)
  PASS  refund webhook(签名) 状态码 (HTTP 200)
  PASS  refund webhook.received (.received=true)
  PASS  validate(退款后) 状态码 (HTTP 200)
  PASS  validate(退款后).status[本地 revoked 优先] (.status=revoked)
  PASS  篡改签名 webhook 被拒 (HTTP 401)
  PASS  无签名 webhook 被拒 (HTTP 401)
  PASS  deactivate 状态码 (HTTP 200)
  PASS  deactivate.status (.status=deactivated)
ALL PASS — MOCK license 端到端冒烟通过（activate→validate→refund→revoked→deactivate + 验签闸门）
```
关键闭环已在真实运行时（非单测桩）证明：
- **本地 revoked 优先于上游 active**：refund webhook 落 D1 后，validate 即便 MockCreem 仍返回 active，facade 也返回 `revoked`。
- **验签闸门**：篡改 1 hex 字符 / 缺 `creem-signature` → 401，验签失败不解析 body。
- 清理已核实：`.dev.vars` 删除、无残留 persist 目录、无残留 8798 端口进程。

> 注：本次运行 `.dev.vars` 由脚本从 `.example` 复制（product=`prod_PLACEHOLDER_...`）。webhook body 的 product
> 取自同一文件，故 product 白名单匹配通过——这正确演示了「product 一致才处理」。仓库另有主 Agent 备好的
> `.dev.vars`（product=`prod_MOCK_appidge`）时脚本会改用它，结论一致。

apps/api 单测（workers-pool + 契约）同域基线：
```bash
cd apps/api && pnpm test     # → Test Files 4 passed；Tests 38 passed（workers）+ 6 passed（contract）
```
覆盖 §6 Worker 必测：有效/无效签名、改一字节即失败、重放幂等、乱序（refund 先于 checkout）、
未知事件/未知 product 安全忽略、activate/validate/deactivate 正常与 4xx/5xx/timeout 映射、
refund/dispute 后本地 revoked 优先、日志脱敏无 key、body 超限/错误 Content-Type/畸形 JSON/限速。**全绿。**

---

## Task 3 · 官网构建 + 链接/CTA/脱敏检查 — PASS

复用 `apps/web/scripts/check-site.mjs`（用生产式公开配置 `PUBLIC_API_BASE_URL=https://api.appidge.com`、
`PUBLIC_POLAR_CHECKOUT_URL`、`PUBLIC_DOWNLOAD_URL=https://updates.appidge.com` 重建站点后断言）。

命令：
```bash
cd apps/web && pnpm test
```
结果：**PASS**（EXIT=0）。最后输出：
```
[build] 8 page(s) built in 710ms
[build] Complete!
站点验收全部通过：8 路由、内部链接、CTA、无 JS、脱敏、法律草稿标记、可访问性结构。
```
覆盖：7 路由 + 404 产物齐全；内部链接无死链；首页/定价含购买链接、定价/下载含下载链接、购买≠下载；
无运行时 `<script>`（仅 JSON-LD），购买/下载为原生 `<a>`（无 JS 可用）；产物**不泄露** `api.appidge.com`
/ `mock` / `PLACEHOLDER` / `x-api-key` / `sk_*` / `.dev.vars` / 私钥头；退款/隐私/条款带「待法务审核」草稿标记；
结构性可访问性（lang / viewport / skip-link / 单一 h1 / meta description / og:title）。

---

## Task 4 · Cloudflare dry-run — PASS

命令：
```bash
cd apps/api && pnpm build     # wrangler deploy --dry-run --outdir dist
```
结果：**PASS**（EXIT=0）。绑定解析正常，最后输出：
```
Total Upload: 50.16 KiB / gzip: 12.12 KiB
Your Worker has access to the following bindings:
env.DB (appidge-licensing)                          D1 Database
env.MOCK_MODE ("true")                              Environment Variable
env.CREEM_API_BASE ("https://test-api.creem.io")    Environment Variable
env.CREEM_PRODUCT_ID ("prod_PLACEHOLDER_xxxxxxxx")  Environment Variable
env.RATE_LIMIT_MAX ("60") / RATE_LIMIT_WINDOW_MS ("60000") / MAX_BODY_BYTES ("16384")
--dry-run: exiting now.
```
> 顶层环境有「multiple environments…」告警（wrangler 提示显式 `--env=""`），仅提示，dry-run 成功。
> secret（CREEM_API_KEY / CREEM_WEBHOOK_SECRET / LICENSE_HMAC_PEPPER）不在 dry-run 绑定里——符合设计（走 `wrangler secret`）。

## 附 · 仓库 secret 扫描 — PASS

```bash
git grep -nE "creem_(test|live)_[A-Za-z0-9]{16,}|whsec_[A-Za-z0-9]{20,}|sk_(live|test)_...|-----BEGIN ... PRIVATE KEY-----" \
  | grep -vE "PLACEHOLDER|_MOCK_|xxxx|change_me|do_not_use"
# → NONE（tracked 文件无真实 secret）
git ls-files | grep -E '\.dev\.vars$|\.env$' | grep -v '\.example'
# → NONE（.dev.vars / .env 未被追踪，仅 .example 占位在库）
```
结果：**PASS** —— 追踪文件无真实 secret，`.dev.vars`/`.env` 未入库。

---

## 缺陷 / 观察

- **代码缺陷：无。** apps/api（44 测试）、apps/web（站点验收）、契约、dry-run 全绿；
  端到端 MOCK 冒烟 17/17。未发现需要退回 owner 修复的功能缺陷。
- **环境观察（非代码缺陷）**：本 Agent 初始被分配的 worktree 分支 `worktree-agent-a9a67c039cb83c293`
  停在旧提交 `198d7a6`（尚无 `apps/api` / `contracts` / `apps/web`）。已将 worktree 切到
  `feat/integration-qa`（= `feat/commercialization-monorepo` 尖端 `2061592`，含全部商业化代码）后
  才能验收。主 Agent 后续为 QA 建 worktree 时，请直接基于集成分支尖端。
- **安装告警（不阻塞）**：worktree 内 `pnpm install --frozen-lockfile` 报 `Ignored build scripts:
  esbuild, sharp, workerd`。功能未受影响（wrangler dev / astro build / vitest 均正常）；如需消除告警，
  可在受控环境 `pnpm approve-builds`。

---

## Task 5 · 人工闸门 Runbook（无法在此自动化，需用户真实操作）

以下三项需要真实凭证 / 真机 / 真实发布，只能由用户手动执行。命令/点击与**通过判据**如下。
更宏观的部署/回滚/密钥轮换见 `infra/cloudflare/README.md` 与 `docs/commercialization-status.md`。

### (a) 真实 Creem sandbox 退款 → 观察 validate 返回 revoked

前置：Creem test 账号；已建 test 产品与 Checkout Link；已在 Creem 配置 webhook 指向本地隧道或
预览 Worker，并拿到真实 webhook secret。

1. 抓真实 webhook 字段（先做，喂给映射层）：
   - `apps/api/.dev.vars`：`MOCK_MODE=false`，填真实 `CREEM_API_KEY`(creem_test_)、
     `CREEM_WEBHOOK_SECRET`(whsec_)、`CREEM_PRODUCT_ID`(prod_)、`CREEM_API_BASE=https://test-api.creem.io`。
   - 本地起 Worker 并用隧道暴露：
     ```bash
     cd apps/api && pnpm exec wrangler dev --ip 127.0.0.1 --port 8787
     # 另开：cloudflared tunnel --url http://127.0.0.1:8787   （或 ngrok），把公网 URL 的
     #        /v1/webhooks/creem 配到 Creem Dashboard 的 Webhook endpoint
     ```
2. Creem test mode 触发一次真实购买（用 Checkout Link + 测试卡）→ 观察 `checkout.completed` 到达。
   用真实版 license key 走一次 activate：
   ```bash
   curl -sS -X POST http://127.0.0.1:8787/v1/licenses/activate \
     -H 'content-type: application/json' \
     -d '{"licenseKey":"<真实test license>","instanceName":"appidge-install-qa","appVersion":"1.0.0"}'
   # 判据：200，status=active，返回 instanceId（记下）
   ```
3. 在 **Creem Dashboard 对该订单发起 Refund**（v1 退款一律 Dashboard 发起，不做公开退款接口）。
   等待 `refund.created` webhook 到达 Worker。
4. 抓取 Worker 收到的**原始 webhook body**（wrangler dev 日志或隧道回放），脱敏后替换
   `contracts/fixtures/creem/refund.created.MOCK.json`（去掉 `_mock`），并核对
   `apps/api/src/creem/mapping.ts` 顶部的 `CANDIDATE_*` 候选键是否命中真实字段名；不命中则在该单一
   模块增删候选键（**不要改 handler**），然后 `cd apps/api && pnpm test` 契约/webhook 测试转绿。
5. 再次 validate 同一 license+instance：
   ```bash
   curl -sS -X POST http://127.0.0.1:8787/v1/licenses/validate \
     -H 'content-type: application/json' \
     -d '{"licenseKey":"<真实test license>","instanceId":"<步骤2 instanceId>","appVersion":"1.0.0"}'
   ```
   - **通过判据**：返回 `status:"revoked"`，且**无论上游 Creem 是否也自动禁用**该 license，本地 deny 都生效。
   - 同时确认 Worker 响应/日志中**不出现**完整 license key 或 `CREEM_API_KEY`（脱敏）。
6. 记录：Creem 是否在退款后也把 license 置为 inactive（观察上游 validate 行为），写回
   `docs/commercialization-status.md` 的 sandbox 证据项。

### (b) macOS 离线 7 天宽限（grace）真机测试

前置：Agent E 的 macOS 授权客户端已集成；一台已激活的真机；离线宽限默认 7 天（配置集中管理）。
（自动化边界测试应由 Agent E 在 Core/AppFeature 用可注入时钟覆盖；本项是真机端到端确认。）

1. 真机正常激活并确认 `licensed`（Keychain 存 license key / instanceId / 上次成功校验时间）。
2. 制造「Worker/Creem 不可用」：断开网络，或临时把客户端 API base 指到不可达地址（用受控构建配置，
   **不要**改成生产真实地址）。
3. 在宽限窗口内（< 7 天）触发校验：客户端应保持 `licensed`（进入 gracePeriod 而非立即 revoke）。
   - **通过判据**：付费能力可用；诊断/帮助不被阻塞；系统网络转发（透明代理）**不因授权服务故障黑洞**。
4. 边界：把系统时钟前拨到「上次成功校验 + 7 天」之后（或用注入时钟的自动化用例）再校验：
   - **通过判据**：宽限到期后进入 `expired`；恢复网络并成功 validate 后回到 `licensed`。
5. 反向确认：明确的 `revoked`/`expired`（真实退款/到期）**立即**锁付费能力，不进宽限。
   区别于「暂时网络失败进宽限」。
6. 时钟异常：把时钟大幅回拨/前拨，确认不会因系统时间被利用绕过到期（grace 以「上次成功校验时间」为锚）。

### (c) 旧版 → 新版 Sparkle + 系统扩展升级 smoke（**最高优先级回归**）

背景：透明代理是**系统扩展**。历史事故——升级换包后 app 会话仍绑在**旧 provider**，旧 provider 终止 =
**全系统流量黑洞**。修复靠「版本握手后重绑」（见 `docs/sparkle-autoupdate.md`、`App/AppidgeApp.swift`
的 `maybeHealStaleBinding()` 与 `App/TransparentProxyController.swift` 的 `restart()`/`reset()`）。
每次发版**必须**人工跑这条；`SUPublicEDKey` 目前是占位 TODO，**未伪造**——先补真实密钥才能签名。

发布前一次性（人工闸门，禁止提交私钥）：
```bash
# 用 Sparkle 官方 generate_keys（在解析后的 Sparkle artifact bin/ 或官方 release tar.xz）
./bin/generate_keys
# → 私钥进登录钥匙串（item: Private key for signing Sparkle updates），终端打印 base64 公钥
# 把公钥填进 App/Info.plist 的 SUPublicEDKey（替换 TODO-REPLACE-WITH-ED-PUBLIC-KEY）
```
发布顺序（对齐 CLAUDE.md §5.6）与 smoke：
1. 出「新版本」包并签名：
   ```bash
   ./scripts/archive-and-notarize.sh      # 公证
   ./scripts/make-dmg.sh                    # DMG
   ./bin/generate_appcast <放着已签名包的目录>   # 生成 appcast.xml 的 EdDSA 签名/length/enclosure
   ```
   校验 codesign / notary / staple / appcast 签名齐全。
2. 把 DMG / appcast.xml / release notes 上传到 R2（`updates.appidge.com`，不可变版本路径，
   `appcast.xml` **最后原子更新**，避免 feed 指向未上传文件；下载直达 R2 不经 Worker）。
3. **在装有上一版生产 App 的真机**上做真实升级 smoke：
   - 打开旧版 App，确认透明代理接管、能正常上网（基线）。
   - 触发 Sparkle：菜单栏「检查更新…」（`MenuBarView` → `updater.checkForUpdates()`），或等自动检查。
   - 确认 Sparkle 校验 EdDSA 签名通过、下载、安装、**退出并重启 App**。
4. **通过判据（回归核心）**：
   - 升级后 App 重启，系统扩展升级到新版 provider，`maybeHealStaleBinding()` 完成**版本匹配后重绑一次**会话。
   - **全系统联网不中断**：升级窗口前后无「流量黑洞」；活动进程仍被正确接管；用户规则仍即时生效。
   - `swift test` 五包、`xcodebuild App Debug` 基线仍绿（回归无引入）。
   - 若任一时刻出现断网，**立即判为失败**（稳定性零容忍），不得发布。
5. 记录旧版号 → 新版号、升级耗时、是否发生短暂断网及自愈时间，写回状态文档。

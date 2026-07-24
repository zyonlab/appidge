# 试用期 + 法务入口：调研与实施规划

> 2026-07-24 · 状态：**规划稿，复杂验证流程待与用户对齐后实施**（§4 是待拍板问题清单）
> 范围：macOS App 试用倒计时与防篡改、App 内法务/购买入口、Legal 页试用条款与 Data Usage 新页

---

## 1. 目标（用户需求原文要点）

1. App 内加入口：Legal（Refunds / Privacy Policy / Terms of Service / Data Usage）+ 购买链接；**链接按 staging/production 打包注入**。
2. 启动即检查凭证；试用中提示**剩余天数倒计时**；提供购买入口；购买后可**输入凭证激活**。
3. 试用判定**防用户篡改首次时间**跳过（重点，先调研）。
4. 试用时长以 Legal 说明为准 = **7 天**；Legal 与实现不一致处更正；Legal 草稿声明去掉。
5. Legal 新增 **Data Usage** 页：说明应用数据使用现状 + **内置规则披露**（应用自身排除、Apple 签名基础设施直连、自动升级)。

## 2. 现状盘点（代码实证，非猜测）

| 能力 | 现状 | 出处 |
|---|---|---|
| 授权状态机 | ✅ 已有 `unlicensed/activating/licensed/validating/gracePeriod/deactivating/revoked`，7 天离线 grace | `Packages/Core` reducer + `LicenseProtocols.swift` |
| 激活/校验/停用 | ✅ 走 facade（现 Creem 上游），Keychain 存 key/instanceId/上次校验时间 | `App/SettingsView.swift:196 LicenseSettingsView` |
| 功能门控 | ✅ `isLicenseActive` 已禁用多处设置项 | `SettingsView.swift` 多处 `.disabled` |
| 构建期链接注入 | ✅ `LicenseAPIBaseURL`/`LicenseCheckoutURL` 由 `ops/environments/<env>.conf` 注入 Info.plist，`build-macos` 有产物断言 | `ops/bin/appidge-ops cmd_build_macos` |
| 试用逻辑 | ❌ 完全没有（无 trial 状态、无首启记录、无倒计时 UI） | 全仓 grep |
| App 内法务链接 | ❌ 没有 | — |
| Legal 试用表述 | 「期限以应用内说明为准」，未写 7 天 | `terms.astro §3` |
| Data Usage 页 | ❌ 没有（privacy 页已覆盖一部分数据说明） | — |

## 3. 调研：试用防篡改怎么做最合理（流行 + 合规）

用户能动的作弊面：①改系统时钟回拨 ②删除本地记录重装“重新开始” ③直接改本地存储的首启时间。业界成熟做法对比：

### 方案 A：纯本地 Keychain 锚点
首启时间写 Keychain（App 卸载重装后 Keychain 条目仍在），文件系统另存一份混淆副本互相校验。
- ✅ 零网络依赖、实现最快；Keychain 条目普通用户几乎不会删（要用 security CLI/钥匙串访问手动找）
- ❌ 挡不住时钟回拨；懂行用户删 Keychain 条目即重置；无审计
- 代表：大量早期 Paddle 时代独立 App（Sketch 旧版等）

### 方案 B：服务端首见锚点（server-anchored trial）
首次启动向 licensing 服务上报隐私友好安装标识（**沿用现有 install-id，隐私政策已披露**），服务端记录 `trial_started_at`（服务器时钟），返回**签名的试用凭据**（含到期时刻）缓存本地；倒计时与到期判定以服务器时间为准。
- ✅ 时钟回拨无效（权威时间在服务端）；删本地/重装后同一 install-id 命中同一条记录；有审计
- ✅ 与现有 facade（api.appidge.com + D1）零新依赖，加一张 `trials` 表 + 一个端点即可
- ❌ 首启需联网一次（离线首启需策略，见 §4-Q3）；重装若换 install-id 可重置（见 §4-Q1，这是隐私承诺换来的已知残余风险）
- 代表：Keygen/LemonSqueezy device-tracked trial、JetBrains、Setapp 类现代做法——**当前主流**

### 方案 C：B + 本地时钟防回拨守卫（推荐）
在 B 之上加两道纯本地守卫，覆盖离线窗口：
1. **单调水位线**：Keychain 记 `maxSeenWallClock`，每次启动/定时更新；若当前时间 < 水位线 − 容差(如 6h) → 判定时钟异常，倒计时冻结并要求联网校时后继续（不锁网络，只锁试用计数的“有利变化”）。
2. **签名凭据不可伪造**：本地缓存的试用凭据由服务端 HMAC/Ed25519 签名（复用 LICENSE_HMAC_PEPPER 体系），到期时刻在凭据内，改本地文件无效。

**结论：推荐 C。** 与现有架构（install-id、Keychain、facade、grace 机制、时钟协议注入可测）完全同构，等于把「license 校验」的既有骨架复用到「trial」上；合规面干净——不采集新数据，隐私政策无需扩权。方案 A 只作为 C 的离线兜底层（首启离线时先本地记名，联网后以服务端锚点归正，取两者较早者）。

### 到期语义（合规红线）
沿用产品既有原则：**授权故障不得造成网络黑洞**。试用到期 = 回到未激活功能面（现 `isLicenseActive=false` 的门控集合），已有转发会话优雅停止/降级，绝不悄悄断网。到期 UI 明确告知 + 购买按钮。

## 4. 待与用户对齐的问题（实施前必须拍板）

| # | 问题 | 选项与建议 |
|---|---|---|
| Q1 | **重装重置 vs 隐私承诺**：privacy 页承诺「不发真实主机名/硬件序列号」。要更强防重置就得引入硬件指纹（哪怕加盐哈希也算采集）。 | 建议：**守住隐私承诺**，接受“抹掉 install-id 重装可再来 7 天”的残余风险（服务端仍可看到同 IP 高频开新试用做风控软限制）。要更强 → 需先改隐私政策再实现。 |
| Q2 | **到期后锁什么**：只锁「按规则转发」核心能力，还是连活动页观察也锁？ | 建议：核心转发能力锁定、界面可看可配但不生效 + 明显购买横幅；与现 isLicenseActive 门控面对齐即可。 |
| Q3 | **离线首启**：完全离线的首次启动允许开始试用吗？ | 建议：允许（本地锚点先行，联网后服务端归正取较早者），24h 内未联网则倒计时旁提示「离线试用中」。不允许=首启强制联网，体验差。 |
| Q4 | **倒计时 UI 位置**：菜单栏常显 / 主窗口横幅 / 仅设置页？ | 建议：主窗口顶部细横幅（剩 N 天 + 购买按钮）+ 设置 License 区详情；菜单栏不加（用户明确说过菜单栏保持克制）。 |
| Q5 | **试用起点**：首次启动即开始，还是首次启用接管时开始？ | 建议：首次**完成引导并启用接管**时开始（用户真正用上才计时，转化更友好）。 |
| Q6 | **Legal 草稿声明移除**：移除即页面成为正式生效文本（此前一直标注待律师审核）。 | 按指示执行，但请确认知悉：移除后即对外承诺。web 测试契约(check-site 的「待法务审核」断言)随动。 |

## 5. 任务拆解（依赖顺序）

### T1 · Worker/API：trial 端点 + D1（TDD）
- D1 migration `0005_trials.sql`：`trials(install_id_hash PK, started_at, expires_at, last_seen_at)`（install-id 服务端加盐哈希存储，沿用脱敏纪律）
- 端点（并入现有 facade，同错误模型）：`POST /v1/trials/claim`（幂等：已存在返回原记录）→ 返回签名试用凭据；`POST /v1/trials/status`（校时 + 续签凭据）
- 必测：幂等 claim、重复 install-id 不重置、凭据签名/篡改拒绝、限速、日志脱敏
- 验收：api 测试全绿 + dry-run

### T2 · Core：Trial 状态机与防篡改守卫（TDD）
- `licensePhase` 扩展 `trial(daysLeft)` / `trialExpired`；reducer 纯函数，时钟/Keychain/API 全协议注入
- 单调水位线守卫 + 签名凭据校验 + 离线兜底锚点；必测：时钟回拨冻结、水位线容差边界、凭据篡改、重装(Keychain 存活)路径、到期前后 1 秒边界
- 验收：Core/AppFeature 测试全绿

### T3 · App UI：倒计时 + 购买 + 凭证输入
- 试用横幅（剩 N 天/已到期 + Buy 按钮 → `LicenseCheckoutURL`）；`LicenseSettingsView` 补试用态展示；凭证输入沿用现有 activate 流
- 中英 String Catalog 补齐；验收：Debug build 无并发 warning + 快照说明

### T4 · App：法务入口 + 链接注入扩展
- 新 Info.plist 键 `SiteBaseURL`（staging=`https://staging.appidge.com` / prod=`https://appidge.com`），`ops/environments/*.conf` + `cmd_build_macos` 注入与断言随动
- 入口：设置新增 About/Legal 区 + Help 菜单——Refund Policy / Privacy Policy / Terms of Service / Data Usage / Buy License（`SiteBaseURL` 拼路径，App 内打开默认浏览器）
- 验收：ops test-config 断言新键；产物 plist 校验

### T5 · Web/Legal：7 天写入 + 草稿声明移除
- terms §3「试用范围与期限以应用内说明为准」→「免费试用 **7 天**（自 <按 Q5 结论> 起算）」；refund 页试用提示同步；中英双语
- 移除 DraftNotice（六页 + 新页），check-site「待法务审核」断言改为反向断言（不得再出现草稿字样）
- 验收：check-site 全绿、双语零残留

### T6 · Web：Data Usage 新页（/data-usage + /zh/data-usage）
内容大纲（全部对应真实实现，逐条给出处）：
1. 网站：无 Cookie/无追踪（同 privacy）
2. App 本地：规则/进程/连接数据只在本机
3. 许可与试用：install-id(随机)、license key、校验时间——发给 api.appidge.com，用途与保留期
4. 自动更新：Sparkle 定期请求 `updates(-staging).appidge.com/appcast.xml`，请求不含个人身份信息
5. **内置强制规则披露**（透明度重点）：
   - 应用自身与代理回环排除（防环，`ProcessOriginExclusion`）
   - **Apple 签名/公证基础设施 6 域名强制直连**（timestamp/ocsp/ocsp2/crl/valid/appstoreconnect.apple.com，PR #53）
   - 上游代理自身流量放行（`UpstreamExclusion`）
6. footer Legal 列表 + App 入口挂链
- 验收：路由/i18n/hreflang/sitemap/check-site 随动全绿

### T7 · 集成回归
全量闸门（五包 Swift + pnpm check + ops 69）+ staging 出包一次走通试用首启→倒计时→模拟到期→激活全流程真机 smoke。

## 6. 里程碑

1. **M0（本文档）**：用户拍板 §4 六个问题
2. M1：T1+T2（后端与状态机，纯 TDD，可并行）
3. M2：T3+T4（App UI/入口）
4. M3：T5+T6（Legal/新页，可与 M1 并行）
5. M4：T7 集成 + staging 真机 smoke → 合 main

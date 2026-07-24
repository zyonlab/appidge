# 试用期 + 法务入口：调研与实施规划

> 2026-07-24 · 状态：**决策已定，可实施**（用户已拍板 §3 全部关键点）
> 范围：macOS App 试用倒计时与本地防篡改、App 菜单法务/授权入口、Legal 页 7 天条款与 Data Usage 新页

---

## 1. 目标

1. **7 天免费试用**，**从首次打开算起**（不是启用接管）。
2. 试用天数**可构建期变量注入**（staging 可设 1 天/几分钟便于调试）。
3. **不用硬件指纹**，**不做服务端锚点**——纯本地防篡改。
4. 未授权时**每次启动都弹窗**（Proxifier 式），弹窗内有购买入口；另有**用户主动打开**的 License 管理入口。
5. App 菜单加 Legal（Refunds / Privacy / Terms / Data Usage）+ 购买 + License 管理入口；链接**按 staging/production 打包注入**。
6. 试用时长以 Legal 为准 = 7 天；Legal 更正并**移除草稿声明**。
7. Legal 新增 **Data Usage** 页：数据使用现状 + 内置强制规则披露（应用自身/回环、Apple 签名基础设施、自动升级）。

## 2. 现状盘点（代码实证）

| 能力 | 现状 | 出处 |
|---|---|---|
| 授权状态机 + 7 天离线 grace | ✅ 已有 `unlicensed/activating/licensed/validating/gracePeriod/…/revoked` | `Packages/Core` reducer, `LicenseProtocols.swift` |
| 激活/校验/停用 + Keychain | ✅ 走 facade（现 Creem），Keychain 存 key/instanceId/校验时间 | `SettingsView.swift:196 LicenseSettingsView` |
| 功能门控 | ✅ `isLicenseActive` 已禁用多处 | `SettingsView.swift` |
| 构建期链接注入 | ✅ `LicenseAPIBaseURL`/`LicenseCheckoutURL` 由 `ops/environments/<env>.conf` → Info.plist，`build-macos` 有产物断言 | `ops/bin/appidge-ops cmd_build_macos` |
| App 菜单命令 | ❌ 只有默认 `Settings {}`，无自定义 App Menu/`.commands` | `AppidgeApp.swift:235` |
| MenuBarExtra | ✅ 已有（保持克制，本次不加倒计时于此） | `AppidgeApp.swift:241` |
| 试用逻辑 / 倒计时 / About 窗口 / Legal 入口 | ❌ 全无 | grep |
| Legal 试用表述 | 「期限以应用内说明为准」，未写 7 天，且带 DraftNotice 草稿声明 | `terms.astro §3` |
| Data Usage 页 | ❌ 无 | — |

## 3. 已定决策（用户拍板）

| 项 | 决策 |
|---|---|
| 试用起点 | **首次启动**即计时（原 Q5「启用接管」改为此） |
| 试用时长 | 7 天，`TrialDurationDays` 构建期注入（prod=7，staging 可调） |
| 防篡改 | 纯本地，**无硬件指纹、无服务端锚点** |
| 未授权行为 | **每次启动弹授权窗**（Proxifier 式），窗内含购买 + 输入凭证 |
| 主动入口 | App 菜单 `Manage License…` |
| 到期锁定面 | 与现 `isLicenseActive` 门控一致，**绝不悄悄断网**（沿用 fail-open） |
| Legal 草稿声明 | 移除（移除即正式生效，用户已知悉） |

## 4. 调研：纯本地防篡改能做到什么程度（合规 + 流行）

放弃服务端锚点后**没有权威时间源**，时钟回拨在理论上无法 100% 阻止——这是纯本地试用的固有边界。业界（Proxifier 自身、Sketch 旧版、大量 Paddle/独立 App）的共识是：**把门槛提高到“普通用户不会绕、绕了不值得”，而非追求密码学不可破**。落地为多锚点交叉 + 单调水位线：

### 4.1 多锚点首启时间（互相校验，取最早）
1. **Keychain 条目**（首选）：`trialStartedAt` 写 Keychain——App 卸载重装后**仍在**，普通用户不会用钥匙串访问手动删。
2. **混淆文件副本**：Application Support 下一份加盐编码的副本（非明文时间戳）。
3. 读取时取两者**较早**的时间为准；任一存在即视为“已开始试用”，杜绝“删一个就重置”。

### 4.2 单调水位线防回拨
- Keychain 记 `maxSeenWallClock`，每次启动/前台化时 `max(旧值, 当前时间)` 更新。
- 启动时若 `当前时间 < maxSeenWallClock − 容差(6h)` → 判定**时钟回拨**：倒计时**冻结在已知最坏值**（按 maxSeenWallClock 计算剩余），显示「检测到系统时间异常」，不因回拨给用户“回血”。
- 附加交叉参考（弱信号，仅用于加固判定，不作硬依赖）：Application Support 目录/Keychain 条目的创建时间、`kern.boottime`。

### 4.3 到期语义（合规红线，不变）
到期 = 回到未授权功能面（现 `isLicenseActive=false` 门控集合）；已有转发会话优雅停止/降级，**绝不网络黑洞**。到期后每次启动弹授权窗（购买 + 输入凭证）。

### 4.4 诚实的边界声明
本方案挡住：改系统时钟、删单个本地记录、普通重装。挡不住：钥匙串+文件全清后重装（可再得 7 天）、专业逆向。**这与用户点名对标的 Proxifier 同级**，是纯本地试用的合理上限；不写任何“绝对防破解”的虚假承诺。

## 5. App 菜单与入口设计（macOS HIG）

用户所指“顶部左起第二个菜单”= **App Menu**（`About`/`Settings`/`Quit` 所在），是放 License 与 Legal 的 HIG 标准位。当前缺自定义 `.commands`，需补：

```
Appidge ▾ (App Menu)
  About Appidge…          → 关于窗口(新增)，内含版本 + Legal 链接四项 + 购买
  ─────────
  Manage License…         → 授权/试用管理窗(新增 CommandGroup after:.appInfo)；未授权时的主动入口
  Settings…               → 已有
  ─────────
  (Services / Hide / Quit  系统默认)

Help ▾
  Refund Policy / Privacy Policy / Terms of Service / Data Usage   → 镜像 About 内链接(SiteBaseURL 拼接)
  Buy a License…          → LicenseCheckoutURL
```

- **About 窗口**：版本号 + 四条 Legal 链接（`SiteBaseURL` 拼 `/refund /privacy /terms /data-usage`，`NSWorkspace.open` 走默认浏览器）+ Buy 按钮。用户找法务的第一直觉在 About，故主入口在此，Help 菜单镜像。
- **启动弹窗（未授权）**：试用中显示「剩 N 天」+ 购买 + 「输入 License」+「继续试用」；到期显示「试用结束」+ 购买 + 输入 License（无“继续”）。已授权不弹。

## 6. 任务拆解（依赖顺序，全 TDD）

### T1 · Core：Trial 状态机 + 本地防篡改守卫
- `licensePhase` 扩展 `trial(daysLeft:Int)` / `trialExpired`；reducer 纯函数，**时钟 / Keychain / 文件存储全协议注入**（可测回拨）。
- 多锚点首启（Keychain + 混淆文件，取最早）+ 单调水位线冻结逻辑。
- `TrialDurationDays` 由注入配置读入（默认 7）。
- 必测：首启记名、第 6 天/第 7 天/到期边界、时钟回拨冻结、容差边界、删单锚点仍判“已开始”、双锚点全在取最早、注入短时长（staging）路径。
- 验收：Core/AppFeature 测试全绿、无并发 warning。

### T2 · App：启动授权窗 + About + Manage License + 菜单命令
- `.commands { CommandGroup(after: .appInfo) { About / Manage License } }` + Help 菜单 Legal/Buy。
- 启动弹窗（试用中/到期两态）、About 窗、Manage License 窗（试用态展示 + 凭证输入沿用现 activate 流 + 购买按钮）。
- 中英 String Catalog 补齐（`SWIFT_EMIT_LOC_STRINGS` 已开）。
- 验收：Debug build 无并发 warning；手动 smoke 三态（试用中/到期/已授权）弹窗与门控。

### T3 · 注入基建：SiteBaseURL + TrialDurationDays
- 新 Info.plist 键 `SiteBaseURL`（staging=`https://staging.appidge.com`，prod=`https://appidge.com`）、`TrialDurationDays`（prod=7，staging 可调）。
- `ops/environments/*.conf` 增两键；`cmd_build_macos` 注入 + 产物 PlistBuddy 断言；`test-config.sh` 断言随动。
- 验收：ops test-config 绿、产物 plist 校验通过。

### T4 · Web/Legal：7 天写入 + 草稿声明移除
- `terms §3`：「试用范围与期限以应用内说明为准」→「**免费试用 7 天，自首次启动起算**」；refund 页试用提示同步；中英双语。
- 移除六页（+ 新 Data Usage 页）的 `DraftNotice`；`check-site.mjs` 的「待法务审核」断言**反转为“不得出现草稿字样”**。
- 验收：check-site 全绿、双语零草稿残留。

### T5 · Web：Data Usage 新页（`/data-usage` + `/zh/data-usage`）
大纲（逐条对应真实实现）：
1. 网站：无 Cookie/无追踪
2. App 本地：规则/进程/连接只在本机，不上传
3. 许可与试用：install-id(随机)、license key、校验时间 → api.appidge.com；试用首启时间**仅存本机**（不上报，呼应“不做服务端锚点”）；用途与保留期
4. 自动更新：Sparkle 定期请求 `updates(-staging).appidge.com/appcast.xml`，不含个人身份信息
5. **内置强制规则披露**（透明度重点）：
   - 应用自身 + 代理回环排除（防环，`ProcessOriginExclusion`）
   - **Apple 签名/公证基础设施 6 域名强制直连**（timestamp/ocsp/ocsp2/crl/valid/appstoreconnect.apple.com，PR #53）
   - 上游代理自身流量放行（`UpstreamExclusion`）
- footer Legal 列表 + About/Help 挂链。
- 验收：路由/i18n/hreflang/sitemap/check-site 随动全绿。

### T6 · 集成回归 + staging 真机 smoke
全量闸门（五包 Swift + pnpm check + ops）+ staging 出包，注入短试用时长走通：首启计时 → 倒计时 → 到期弹窗 → 输入凭证激活 → 菜单 Legal 链接开对页 → 时钟回拨冻结验证。

## 7. 里程碑

- **M1**：T1（状态机+防篡改，纯 TDD）
- **M2**：T2+T3（App UI/菜单/入口 + 注入基建）
- **M3**：T4+T5（Legal 更正 + Data Usage，可与 M1 并行）
- **M4**：T6 集成 + staging 真机 smoke → 合 main

## 8. 仍需确认（非阻塞，实施中可回填）
- About 窗口是否也显示 build 号/更新检查按钮（建议：显示版本 + “检查更新”走 Sparkle）。
- 启动弹窗在“试用中”是否可「今天不再提示」（建议：不提供，与 Proxifier 一致每次弹，但按钮顺序把“继续试用”放显眼位，降低打扰感）。

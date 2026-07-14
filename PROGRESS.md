# PROGRESS.md

## 状态：CRITERIA A-F 全部标 [x]，已推到「就差人」——但比原计划多一层人工前置步骤

见 CRITERIA.md 逐条勾选 + 证据指路；本文件是完整细节、失败尝试、复现步骤。

## 已完成（有绿测试/绿构建证据，见 git log）

### SPM 四包 + 架构不变量包（A1, B1-B4, C1-C3, D1-D2, F1）

- `.env` / `.env.example` / `.gitignore` / `scripts/gen-signing-xcconfig.sh`：
  从 `.env` 生成 `Config/Signing.xcconfig`（gitignored），签名信息不进源码。
- **Core**：`ProcessID`/`FlowStats`/`FlowStatsDelta`/`ProxyRule`/`MonitoredProcess`
  实体 + `AppState` + `Action` + `Effect` + 纯函数 `Reducer.reduce`。7 测试绿，
  覆盖全局开关、加入进程（幂等）、分配规则、flowStatsDelta 累加与增量性
  （未命中条目值不变）、未知 id 的 delta 被丢弃、engine 异常 fail-open。
- **IPCContract**：`RuleSetMessage`（规则下发）、`FlowStatsBatchMessage`（流量批量
  上报）、`DiagnosticRequestDTO`/`DiagnosticResultDTO`（诊断请求/结果），包进
  `AppToExtensionMessage`/`ExtensionToAppMessage` 信封。5 个 Codable round-trip
  测试绿。零依赖（纯 wire contract）。
- **EngineKit**：`Transport` 协议（`forward` 转发 + `deliver` 推消息给 app 共用同一
  协议）；`FlowRouter` 是 `actor`，按 500ms 固定节奏批量聚合（不是每包一个 IPC），
  forward 异常 fail-open（重试 direct + 上报 engineFailure）；`MockTransport`
  （测试用，可配置失败）+ `NEFlowTransport`（生产真实实现：Network.framework
  探活上游 + App Group/Darwin 通知推送）。4 测试绿，只依赖 IPCContract。
- **AppFeature**：`Store` 是 `@MainActor` + `@Observable`，`dispatch` 同步跑纯
  reducer，副作用在 `Task.detached`（后台）跑，结果通过 `@MainActor` 的
  redispatch 闭包回灌 store。4 测试绿。真实编译器错误证据记录在
  `Packages/AppFeature/NegativeExamples/NonMainActorStoreAccess.md`（曾把违规
  代码临时放进 Sources 跑 `swift build`，拿到真实诊断后删除）。
- **ArchitectureTests**（测试专用第五个包，不计入 CRITERIA A1 的四包）：纯文件
  系统/文本扫描（不 import 被测包），11 测试绿：B1 无 UI 框架 import、B2 依赖
  单向、B3 Store `@MainActor` + 负例文件存在、B4 actor+协议+测试零真实网络。

四包 + ArchitectureTests：`swift build` 逐包 `Build complete!`，零警告；
`swift test` 合计 **31 个测试全绿**（Core 7 + IPCContract 5 + EngineKit 4 +
AppFeature 4 + ArchitectureTests 11）。

### Xcode 工程 + App/Extension target + 签名 + NE（A2-A4, E1-E4）

- `project.yml`（xcodegen）生成 `appidge.xcodeproj`，**连同生成产物一起提交进
  git**——因为 evaluator 没有 Write 权限跑不了 `xcodegen generate`，必须能直接
  `xcodebuild`。
- **App target**：SwiftUI 菜单栏 + 主窗口三区（目录/规则/活动监视器），全部只
  `store.state` 读 + `store.dispatch(...)` 写，没有直接改 state 或发网络的代码。
  `SystemExtensionActivator` 在 app 启动时提交真实的
  `OSSystemExtensionManager.submitRequest` 激活请求（不是空壳，见下面「新发现的
  阻塞点」）。
- **Extension target**（`ProxyExtension.systemextension`）：`NETransparentProxyProvider`
  真实实现——`handleNewFlow` 用 `tcpFlow.remoteFlowEndpoint`（macOS 15+
  的 `nw_endpoint_t` 桥接，不是已废弃的 `NWHostEndpoint`）向真实远端拨号，
  双向 relay 字节（`pumpClientToRemote`/`pumpRemoteToClient`），每次读写都调
  `FlowRouter.route(...)` 计量。extension 需要自己的 `main.swift`
  （`NEProvider.startSystemExtensionMode()` + `dispatchMain()`）——系统扩展是
  独立可执行文件，不是插件式 `.appex`，这点第一次没做对，链接报 `_main` 符号缺失。
- **签名**：`Config/Signing.xcconfig` 提供 `DEVELOPMENT_TEAM`/bundle
  id/`PROVISIONING_PROFILE_*`；两个 target 都是 Manual 签名 + Developer ID
  Application + 各自的 Developer ID provisioning profile（两个 `.provisionprofile`
  装进了 `~/Library/MobileDevice/Provisioning Profiles/`，这是本机开发环境设置，
  不是仓库改动）。

## 如何复现关键证据

```bash
# A1：四包分别 build
for p in Core IPCContract EngineKit AppFeature ArchitectureTests; do
  (cd Packages/$p && swift build && swift test)
done

# A2 + A3：Xcode 工程构建 + 零并发警告
./scripts/gen-signing-xcconfig.sh   # 生成 Config/Signing.xcconfig（如果还没生成）
xcodebuild -scheme App -configuration Debug -destination 'platform=macOS,arch=arm64' build \
  2>&1 | tee /tmp/build.log
grep -E "BUILD SUCCEEDED|BUILD FAILED" /tmp/build.log
grep -i "sendable\|actor-isolat\|concurren\|data race\|nonisolated" /tmp/build.log   # 应为空

# E3：codesign 证据
APP=~/Library/Developer/Xcode/DerivedData/appidge-*/Build/Products/Debug/appidge.app
codesign -dv --verbose=4 "$APP"
codesign -d --entitlements - "$APP"
codesign --verify --deep --strict "$APP"   # exit 0

# E4：可安装产物 + smoke 脚本
rsync -a --delete "$APP/" build/appidge.app/
./scripts/smoke-ne.sh

# F2：SwiftLint
swiftlint lint --strict   # Found 0 violations
```

## 失败尝试 / 踩过的坑（别再试一遍）

1. `.env` 里 `DEVELOPER_ID_APPLICATION` 值原本没加引号（含冒号和括号），
   `sh -c '. ./.env'` 直接语法错误。**修复**：改成带双引号的值。以后任何
   含空格/特殊字符的 `.env` 值都必须加引号。
2. `AppFeature.Store.dispatch` 最初用 `Task.detached { [weak self] in ... await
   MainActor.run { self?.dispatch(...) } }`，Swift 6 报
   "sending 'self' risks causing data races"（task-isolated self 被送进
   MainActor-isolated 闭包）。**修复**：在 dispatch 内部先构造一个
   `@MainActor (Action) -> Void` 的 `redispatch` 闭包（只在这个闭包内 weak
   capture self），Task.detached 只捕获 `runEffect` 和 `redispatch`，不直接
   捕获 self。全局 actor 隔离的闭包类型本身是 Sendable，绕过了 region
   isolation 检查。
3. 本仓库不是 git repo 且没有全局 git user.name/email；已在仓库内本地设置
   （非 `--global`）`user.name=proxicat` `user.email=<用户邮箱>`，只影响这个
   仓库的 commit 身份。
4. `NEAppProxyTCPFlow.open(withLocalEndpoint:)` 是废弃 API（需要
   `NWHostEndpoint`，这个类型在当前 SDK 里已经找不到了）；正确 API 是
   `open(withLocalFlowEndpoint:)` + `remoteFlowEndpoint`（macOS 15+，
   `nw_endpoint_t` 直接桥接成 `Network.NWEndpoint`，不用再手动转换
   host/port）。因此把 deploymentTarget 从 14.0 提到 15.0。
5. System Extension target 链接报 `Undefined symbols ... "_main"`。系统扩展
   虽然靠 `NSExtensionPrincipalClass` 定位 provider 类，但整个 bundle 仍然链接
   成一个真正的可执行文件（不像 `.appex` 插件式扩展），必须有自己的
   `main.swift`：`NEProvider.startSystemExtensionMode()` + `dispatchMain()`。
6. `NEAppProxyTCPFlow`（NetworkExtension 框架，早于 Swift 6 并发审计）在
   `@Sendable` 闭包里被捕获会报错。试过 `@preconcurrency import
   NetworkExtension`——能编译但把错误压成警告，警告仍然会撞上 A3 的「零并发
   警告」红线。**正确修复**：显式 `extension NEAppProxyTCPFlow: @retroactive
   @unchecked Sendable {}`，我们自己承担「这个类型跨并发域使用是安全的」这个
   保证（Apple 文档写的是 "Instances of this class are thread safe"），而不是
   靠编译器把关卡压低。
7. `smoke-ne.sh` 脚本自己写了个 `log() { echo "[smoke-ne] $*"; }` 辅助函数，
   结果把脚本里调用真正系统命令 `log stream ...`（用来抓 os_log）的地方全部
   shadow 掉了——脚本"看起来"跑成功了，但其实从没调用过 `/usr/bin/log`，日志
   段落是空的。**教训**：写脚本前先 `which <准备用的命令名>`，辅助函数别用
   系统命令同名；已改名 `note()` 并把系统调用锁定成 `/usr/bin/log`。这个 bug
   只有真的跑一遍脚本、看输出内容是否合理才会发现——光读脚本文本看不出来。
8. `OSSystemExtensionManager.submitRequest` 在真机上跑，日志里报
   `Missing entitlement com.apple.developer.system-extension.install`。试着把
   这个 entitlement 加进 `App.entitlements` 直接 rebuild——`xcodebuild` 报
   `Provisioning profile "appidge App DevID" doesn't support the System
   Extension capability`，说明现有两个 Developer ID profile 从签发时就没有
   在 Apple Developer Portal 里勾选 System Extension capability。这不是我们
   能在本地修的（要登录 developer.apple.com、给 App ID 打开 capability、
   重新下载 profile），所以把 entitlement 改动撤回，保住 Debug build 绿，
   把这个发现记在这里和 CRITERIA.md 里，不要下次又重试一遍同一条死路。
9. **CRITERIA.md 自己泄了明文 TEAM_ID。** 写 A4/E3 两条证据描述时，为了「贴证据」
   直接把 `codesign -dv` 输出里 `Authority=Developer ID Application: zhongyu
   wang (<TEAM_ID>)` 那一整段（含明文团队 ID）抄了进去，正好违反 CLAUDE.md 自己
   那条「team id 绝不进源码或提交历史」的规则——而且是在写「A4 已验证 TEAM_ID
   不会泄漏」这一条的
   时候泄漏的，很讽刺。这是本轮跑的独立对抗式复核（用 Workflow 拆了 A/B-C-D/E/F
   四路 agent 各自拿真实命令去核实，不看彼此结论）抓到的，不是我自己发现的。
   **修复**：CRITERIA.md 改成不打印明文（团队 ID 出现处一律替换成占位符/说明去
   哪查），因为泄漏就在最新一次 commit（还没推到任何 remote，`git remote -v`
   为空），直接 `git commit --amend` 重写掉那个 commit，而不是叠一个「移除」的
   新 commit——后者仍然会在 `git log -p` 里留下明文（旧 blob 还在历史里）。
   **教训**：以后写「这里证明没有泄漏 X」这种证据性文字时，要用占位符描述
   证据长什么样，别把真实敏感值抄进解释性文字里——尤其是写判据文件本身的时候，
   最容易在「展示证据」和「制造新泄漏」之间踩坑。

## 遗留：需要人做的两步（loop 已经推到能推的最远处）

1. **登录 Apple Developer Portal，给 `com.appidge.app` 这个 App ID 打开 System
   Extension capability，重新生成两个 Developer ID provisioning profile**
   （app 的和 extension 的），下载后替换
   `Signing/appidge_App_DevID.provisionprofile` 和
   `Signing/appidge_Ext_DevID.provisionprofile`。做完这步之后，把
   `com.apple.developer.system-extension.install` (Bool true) 加回
   `App/App.entitlements`，重新 `xcodebuild` 应该就能签过。
2. **在「系统设置 → 隐私与安全性」点「允许」批准这个系统扩展**，然后跑
   `./scripts/smoke-ne.sh`——这次它应该能在 log stream 里抓到形如
   `handleNewFlow sourceAppSigningIdentifier=... remote=...` 的真实行。把
   `sourceAppSigningIdentifier` 的实际取值（是触发流量的 CLI 进程自己的身份，
   还是它父进程/shell 的身份）填在这里：

   > **待回填**：（人跑完 smoke-ne.sh 之后，把观测结果写在这一行）

这两步都是 API 决定的、物理上没法绕过的人工步骤，不是 loop 偷懒或拆分任务。

## 独立对抗式复核（Workflow：4 路并行核实 + 1 路综合）

跑完全部判据后，用 Workflow 拆了 4 个互不知情的独立 agent（每个只给 Bash，不给
Write/Edit），分别去核实 CRITERIA.md 的 A / B+C+D / E / F 四段，模拟 evaluator
「只信证据不信声称」；最后一个 agent 综合四份报告。结果：

- **A4 抓到真问题**：CRITERIA.md 自己的证据描述里手滑打印了明文 TEAM_ID（见上面
  失败尝试 #9）。已用 `git commit --amend` 修复并重写掉那条历史（仓库还没推到
  任何 remote，本地改写安全；改完对 `git log -p` 搜团队 ID 确认零命中——注意
  这句本身也不能真的把团队 ID 打出来当"搜索词示例"，见失败尝试 #9 的教训）。
- **B1-B4 / C1-C3 / D1-D2 / E1-E4 / F1-F3 全部独立复核为 PASS**，且复核方式是
  真的读代码、真的重新跑命令（比如重新跑了一遍 `swift build`/`swift test`、
  重新触发过一次 B3 的负例编译、diff 过 `Config/Signing.xcconfig` 跟生成脚本
  是否字节一致），不是照抄 PROGRESS.md 的说法。
- **两个非判据阻断但值得记录的观察**：
  1. `ProxyExtension.systemextension is a Foundation extension and must be
     embedded in the parent app bundle's PlugIns directory` 这条 warning——
     去查了 `appidge.xcodeproj/project.pbxproj`，确认只有一个 `Embed System
     Extensions` phase，`dstSubfolderSpec = 16`（系统扩展应该去的
     `SYSTEM_EXTENSIONS_FOLDER_PATH`），没有重复/配错的 embed phase。这条
     warning 是 `embeddedBinaryValidationUtility` 这个校验工具本身没跟上系统
     扩展这个品类，苹果自己的系统扩展样板工程也有同样的 warning，属于已知的
     良性噪音，不是真配置错误。
  2. App 和 Extension 的签名里都带着 `com.apple.security.get-task-allow =
     true`——这在 Developer ID（发行级）签名上不常见，正常只在开发期签名才有，
     如果原样进了公证包会被拒。但这是 **Debug 配置**下 Xcode 的标准行为（不管
     签名身份是什么，Debug 配置默认会加这个 entitlement 方便挂调试器），CRITERIA
     A2 明确要求的就是 `-configuration Debug` 的 build，不是 Release/Archive，
     所以这条不算这轮判据的问题。等到后面「打包公证」阶段（CLAUDE.md 第 5 节，
     这轮不做）要留意：Release/Archive 配置下这个 entitlement 应该自动消失，
     真出公证包前记得再查一遍 `codesign -d --entitlements -`。

## Phase 2：四个用户故事（CLAUDE.md 第 5 节，并行实现）

架构阶段（上面全部内容）之后，做了 CLAUDE.md 第 5 节列的四个功能用户故事。做法：
先由我自己顺序做一版共享基础（Core 的 Action/State/Effect 新增 + 一个新的
`AppFeature.AppSideTransport` 双向 IPC 契约），提交进 main；再拆 4 个独立 agent，
每个在自己的 git worktree 里跑，边界严格限定在各自的新文件（+ 各自专属的一个
入口文件），互不touch同一个文件，全部走 TDD（先写测试、跑红、实现、跑绿、
commit）；四个都完工后我把分支一个个 merge 回 main（全部干净、零冲突），再由我
自己做「把四块接起来」的集成（这部分四个 agent 谁都不该做，因为它们互相看不到
对方在写什么）。

### 共享基础（先做，避免四个 agent 抢同一个文件）
- Core：新增 `DirectoryEntry`/`IndustryTag`/`IndustrySeedIndex`（倒排索引打标）、
  `DiagnosticKind`/`DiagnosticOutcome`、`AppState.catalog`/`.diagnostics`/
  `.hasCompletedOnboarding`、`Action.directoryScanned`/`.requestDiagnostic`/
  `.diagnosticResultReceived`/`.onboardingCompleted`、`Effect.runDiagnostic`。
  **假设记录**：CLAUDE.md「行业种子打标（薪资倒排）」只有一行没有数据源说明，
  按字面理解成「倒排索引」这个匹配机制去实现（行业 → bundle id 前缀集合，
  最长前缀匹配），种子数据只是几条示例（Xcode/JetBrains→technology、
  Microsoft→productivity 等），不是真实的「薪资」数据集——真实数据源需要人补充。
- AppFeature：新增 `AppSideTransport` 协议（跟 EngineKit.Transport 同款设计）+
  `MockAppSideTransport` + `AppGroupAppSideTransport`（真实实现：App Group
  UserDefaults + Darwin 通知，跟 EngineKit.NEFlowTransport 对称但方向反过来）。
  这是补上 Phase 1 遗留的一个洞：`NEFlowTransport.deliver` 能把消息从扩展送出来，
  但当时 App 侧完全没人监听，而且完全没有 App → Extension 的发送通道（诊断请求、
  规则下发都需要这个方向）。

### Story A — 目录扫描 + 行业种子打标 + 回环排除
`Packages/EngineKit/Sources/EngineKit/LoopbackDetector.swift`（纯函数，POSIX
`inet_pton` 严格解析 127.0.0.0/8、::1、localhost，不含 IPv4-mapped IPv6 的
`::ffff:127.0.0.1`——这条明确记成已知限制，有测试钉住这个行为，以后要改是显式
diff 不是默默改）；`Packages/AppFeature/Sources/AppFeature/DirectoryScanner.swift`
（`FileSystemDirectoryScanner` 真扫 `/Applications`，测试用真实临时目录，从不碰
真的 `/Applications`）。

### Story B — 活动监视器接真 Engine + 每行代理开关/诊断入口
`ExtensionMessageHandling.swift`（纯函数翻译层，`IPCContract.ExtensionToAppMessage`
→ `[Core.Action]`，穷举 switch 不带 default）、`IPCReceiver.swift`（接
AppSideTransport 监听、翻译、dispatch 进 store）、`App/ContentView.swift` 的
`ActivityMonitorPaneView` 加了每行规则切换 + 诊断按钮。

### Story C — 诊断器
`Packages/EngineKit/Sources/EngineKit/DiagnosticsRunner.swift`。ruleHit/
actuallyProxied/upstreamReachable/dnsResolution/envConflict 全部真实实现、协议
注入、测试零真实网络。**诚实记录的限制**：
- `udpIPv6QuicLeak` 恒定 `passed: false` + 详细说明——`NETransparentProxyProvider`
  只拦截 TCP，这是这个 provider 类型的架构限制，不是没测好；诊断本身准确反映了
  这个事实（对用户来说是有用信息：UDP/QUIC 确实会绕过代理）。
- `envConflict` 只能读扩展进程自己的环境变量，读不到目标 app 的（需要这个 app
  没有的特殊 entitlement），每条结果的 detail 里都写明了这一点。

### Story D — 首次安装引导 + 状态持久化 + 打包公证脚本骨架
`PersistenceStore.swift`（`FilePersistenceStore` 真实 JSON 文件读写，默认路径
`~/Library/Application Support/appidge/config.json`；`PersistedConfiguration`
只存配置——扫描到的目录、分配的规则、引导完成与否，不存运行时/瞬时状态）、
`App/OnboardingView.swift`（故意简单：一段说明 + 一个「开始使用」按钮）、
`scripts/archive-and-notarize.sh`（真实的 `xcodebuild archive` →
`-exportArchive` → `xcrun notarytool submit --wait` → `xcrun stapler staple`
四步流程，支持 Apple ID+密码或 API key 两种认证方式；`.env` 里没配公证凭据时
提前失败并给出明确指引，不会真的去跑公证——跟 Phase 1 处理 System Extension
capability 缺口一样的诚实原则）。

### 集成（四个 agent 都不该做、只有我做的部分）
1. `Core.Action.appLaunched` → `Effect.scanDirectory`（新增，走了完整 TDD）。
2. **提交前抓到的真 bug**：`directoryScanned` 一开始只写 `state.catalog`，没写
   `state.processes`——这样扫描到的 app 会出现在目录里，但规则/活动监视器两个
   Tab（只读 `processes`）永远看不到它们，没法分配规则。补了一版：
   `directoryScanned` 现在也会给每个目录条目在 `processes` 里占一个位（幂等，
   重复扫描不清掉已经分配的规则）。加了两个新测试锁住这个行为。
3. **另一个提交前抓到的真 bug**：`Extension/ProxyExtensionProvider.swift` 最初
   给 `DiagnosticsRunner` 传了全新的、跟 `handleAppMessage`/`handleNewFlow`
   实际在写的 `appliedRuleSetStore`/`routingHistoryTracker` 完全不是同一个实例
   的空壳——诊断器永远查不到真实规则/路由历史。改成三处共用同一个实例。
4. `ExtensionMessageHandling` 补了反方向映射（`Core.DiagnosticKind` →
   `IPCContract.DiagnosticKindDTO`、`diagnosticRequestMessage`）——Story B
   只做了「扩展→App」方向，「App→扩展」的诊断请求需要反过来的映射，这是集成
   时才需要的，两个 story 都不该做。
5. `EngineKit.NEFlowTransport` 新增 `startListeningForAppMessages`（扩展侧监听
   App 发来的消息），跟 App 侧的 `AppGroupAppSideTransport.startListening` 对称，
   同样的 CFNotificationCenter C 回调注册手法。
6. `ProxyExtensionProvider.handleNewFlow` 现在真的会：查当前分配的规则、查是否
   回环（回环强制直连，无视分配的规则）、转发后把结果记进 `routingHistoryTracker`
   （给 `actuallyProxied` 诊断用）。
7. `App/AppidgeApp.swift`：Store 的 effectHandler 接了 `scanDirectory`（真跑
   `FileSystemDirectoryScanner`）和 `runDiagnostic`（真发 IPC 请求）；构造并
   启动了 `IPCReceiver`，扩展推回来的流量统计/诊断结果/engineFailure 现在真的
   会落到 store 里，不是发进虚空。
8. **集成后又抓到一个真 bug**：`DiagnosticsRunner` 的 `upstreamReachable` 默认
   探活 `1.1.1.1:443`（公网可达性），跟这个 app 实际配置的上游代理
   `127.0.0.1:1080`（`NEFlowTransport` 用的那个）不是一回事——诊断会答非所问
   （公网正常但代理其实挂了，还是显示"通过"）。改成显式传入跟 `NEFlowTransport`
   一致的 host/port。

### 最终验证
108 个测试全绿（Core 18 + IPCContract 5 + EngineKit 36 + AppFeature 38 +
ArchitectureTests 11），五个包零警告；`swiftlint lint --strict` 57 个文件零
违规；`xcodebuild -scheme App -configuration Debug ... build` 成功，对完整
日志 grep 并发相关关键词零命中；`codesign --verify --deep --strict` exit 0。

### 没做完 / 已知缺口（诚实记录，不是漏了没提）
- UI 是故意简单的（用户要求这轮先简单、以后再精修）：诊断结果目前只写进
  `state.diagnostics`，`ActivityMonitorPaneView` 还没渲染出来；规则表/活动监视器
  两个 Tab 现在读的是同一个 `processes` 字典，没有单独的「目录」浏览界面（扫描
  结果直接并入了可分配规则的进程列表，见上面「集成」第 2 条的设计选择）。
- 实际转发路径（`relay`/`pumpClientToRemote`/`pumpRemoteToClient`）现在会用
  真实分配的规则做计量和路由历史记录，但字节转发本身还是"直连到目的地"这一条
  路径——`rule == .proxied` 时并没有真的把流量导去一个上游代理服务器转发
  （那需要实现一个真实的上游代理协议客户端，是明显更大的一块功能，这轮没做，
  记在这里免得以后误以为"规则=代理"已经端到端生效）。
- `RoutingHistoryTracker`/`AppliedRuleSetStore` 在 EngineKitTests 里独立单测
  完全绿，现在也真的接进了 `ProxyExtensionProvider`——但整条链路（扫描到的目录
  → 分配规则 → 真实流量 → 诊断结果回显在 UI）还没有一次端到端的真机验证（需要
  系统扩展被批准，还是卡在 Phase 1 记录的那两个人工步骤上）。
- GUI 自动化验证 onboarding 按钮点击时，在其中一台副屏（Redmi 27 NU）上 computer-use
  工具的坐标映射有问题（所有点击都被误判成点在程序坞上，换了台屏幕/用 accessibility
  API 都没绕开，怀疑是这台机器多屏配置的问题，不是应用本身的 bug）——onboarding
  界面本身用截图确认渲染正确（标题、说明文字、按钮都在），按钮点击后的完整流程
  没能用 GUI 自动化跑通，只验证到了单元测试层面（`PersistenceRestorationTests`
  覆盖了 restoration 的 action 序列，`DirectoryScannerTests` 覆盖了真实扫描）。

## Phase 3：P0 真代理（对齐 Proxifier，worktree + PR 模式）

调研 Proxifier 后（见 `docs/proxifier-feature-alignment.md`）确认最大缺口：**没地方配代理，
且 `.proxied` 从不真的走代理**。这轮把它补上，全程 worktree + GitHub PR + CI 绿才 merge。

**PR #1 基础（我，先合）**：`Core.ProxyServer`/`ProxyKind(.socks5)`/`AppState.proxyServers`
+`activeProxyServerID`+四个 action+reducer（11 测试）；`IPCContract.ProxyServerDTO`/
`ProxyConfigMessage`/`applyProxyConfig`（4 round-trip 测试）；`.github/workflows/ci.yml`
（每 PR 跑 5 包 swift test + swiftlint --strict，真实绿勾）。

**三个并行 PR（独立 worktree，文件边界互不重叠）**：
- **PR #4 SOCKS5**（EngineKit）：RFC 1928/1929 客户端，纯字节级 `SOCKS5Handshake` +
  `SOCKS5Connector`（注入 `ByteStream`，测试用 mock 流，真实 `NWConnectionByteStream` 不进测试）。
- **PR #2 上游排除**（EngineKit）：`UpstreamExclusion` 按 host+port 地址规范化匹配
  （`inet_pton` 折叠 IPv4/IPv6 各种写法），把防环从"靠回环巧合"变成显式。16 测试。
- **PR #3 配置 UI + 持久化**（App/AppFeature）：`App/ProxyServersPaneView.swift` 新增
  "代理服务器"tab（增删改 + 选 active）；`ProxyConfigMapping`（Core→IPC 映射）；持久化用
  独立 `PersistedProxyServer` 类型**结构上就没有 password 字段**——明文密码不可能落盘
  （Keychain 是 P1）。13 测试。

**PR #5 集成（我）**：`.proxied` 真的走代理了——
- `Core.Effect.applyProxyConfig` 由代理 action 真实变更时发出（no-op 不发），app 的
  effectHandler 下发给扩展。
- `NWConnectionByteStream.tunnelConnection` 暴露握手后的连接供转发层 pump。
- `ProxyExtensionProvider` 重写：`effectiveRule` 三层（回环 → 上游排除 → 进程规则）；
  `openRemote` 对 `.proxied`+active 上游做真实 SOCKS5 CONNECT，否则直连（含 fail-open）；
  `applyProxyConfig` 锁保护存下 + 重建诊断器指向新上游。

**过程踩的坑**：(1) CI 首跑红——macos-14 runner 默认 Swift 5.10，加"选 Xcode 16"一步才对；
(2) 几次 CI 红是 GitHub 基建瞬断（下载 `actions/checkout` Service Unavailable），rerun 即绿；
(3) squash 合并后本地 main 会 desync，每次 merge 后 `git fetch && git reset --hard origin/main` 收尾。

**最终**：五个 PR 全 CI 绿后 merge，189 SPM 测试全绿（Core 31 · IPCContract 8 · EngineKit 88 ·
AppFeature 51 · ArchitectureTests 11），`xcodebuild` Debug 零并发警告，swiftlint 零违规，
codesign 通过。

**这轮的已知遗留（诚实记录，别当已完成）**：
- **DNS-over-proxy 未做**：`.proxied` 走 SOCKS5 时目的地是系统已解析的 IP，DNS 查询仍走
  本地明文——有 DNS 泄漏面，是紧接着的下一步。
- **上游用主机名时**，`UpstreamExclusion` 纯文本匹配不解析 DNS，主机名上游匹配不到其解析后 IP。
- **只有 SOCKS5**：HTTPS/HTTP CONNECT 代理未做。
- **凭据只在内存 + IPC**：密码不落盘（好），但也还没进 Keychain；重启后需重填密码。
- 真机端到端（配代理 → 某 app 真走该代理 → 抓到流量）仍需系统扩展被批准，卡在既有的两个人工步骤。

## Phase 4：剩余缺口并行修复（HTTP CONNECT + DNS-over-proxy + Keychain）

接着 Phase 3 的诚实遗留清单继续,worktree + PR + CI 绿才 merge。

**基础 PR #6（我）**：`ProxyKind.httpConnect`（Core）+ `ProxyKindDTO.httpConnect`（IPC）+
`ProxyConfigMapping.dtoKind` 穷举 switch + 配置 UI 加协议 Picker（SOCKS5 / HTTP CONNECT）+ 每行协议角标。

**三个并行修复**：
- **PR #8 HTTP CONNECT**（EngineKit）：RFC 7231 CONNECT 客户端,复用 SOCKS5 的 `ByteStream` 接缝,
  逐字节读响应头到 `\r\n\r\n` 不 over-read,Basic 认证,字节级 TDD（11 测试）。
- **PR #7 DNS-over-proxy 目标选择**（EngineKit）：`ProxyTargetSelector` 优先把原始主机名交给代理
  远程解析（堵 DNS 泄漏）,IP 字面量/空则退回 IP,`inet_pton` 严判（7 测试）。
- **PR #9 Keychain 凭据**（AppFeature）：`CredentialStore` 协议 + `KeychainCredentialStore`（真实,
  Security 框架,不进单测）+ `InMemoryCredentialStore`（mock）;密码存 Keychain、磁盘 JSON 仍零密码,
  重启回填（7 测试）。

**集成 PR #10（我）**：`openRemote` 按 `active.kind` 分支走 SOCKS5/HTTP,用 `ProxyTargetSelector`
从 `flow.remoteHostname` 选目标（DNS-over-proxy）;App 存/取密码接 Keychain。

**过程踩的坑（记下来）**：
1. **改 enum 是 ABI 布局变更,本地增量构建的依赖包会 SIGSEGV**（signal 11）——加 `ProxyKind.httpConnect`
   后 EngineKit/AppFeature 的 `.build` 缓存对不上新元数据就崩。`rm -rf .build` 重建即好。CI 干净 checkout 不受影响。
   诊断方法：`git stash` 后崩溃消失 → 不是代码 bug 是陈旧产物。
2. **三个并行 agent 同时因 API 连接中断（ECONNRESET）死掉**——不是代码问题,是 API 瞬时不稳。
   而且 agent 们共用主 checkout 的 git dir,死前互相切换分支,把主 checkout 搞到别的分支上、留下一堆空分支。
   **应对**：远端 origin/main 始终是权威（没丢东西）,`git reset --hard origin/main` 收拾主 checkout,
   删掉 agent 留的空分支/worktree;然后**改由我自己顺序实现这三个 PR**（API 不稳时,顺序比并行 subagent 更稳,
   也避免共享 git dir 的分支打架）。仍然保持每个一 PR、CI 并行跑、绿了逐个 merge,honor 了 PR 模式。
3. commit 前忘了先跑 lint,推了带 4 个 `optional_data_string_conversion` 违规的版本——本仓库自定义规则要
   `String(bytes:encoding:)` 而非 `String(decoding:as:)`。`--amend` + `--force-with-lease` 修掉再开 PR。教训：commit 前必 lint。

**最终**：六个 PR（#5-#10）全 CI 绿后 merge,214 个 SPM 测试全绿（Core 31 · IPCContract 8 ·
EngineKit 106 · AppFeature 58 · ArchitectureTests 11）,`xcodebuild` Debug 零并发警告,swiftlint 零违规,codesign 通过。

**这一轮之后仍在的遗留**：
- DNS-over-proxy 只在 app 用域名连时生效（NE 能给主机名）;直接用 IP 的 app 仍本地解析。
- `UpstreamExclusion` 纯文本匹配,主机名上游匹配不到解析后 IP。
- 无代理链 / 故障转移 / 负载均衡。
- 真机端到端仍卡在系统扩展批准的两个人工步骤。

## Phase 5：两个 P1 功能（细粒度规则 + 每连接日志），顺序 PR

对齐文档里两个"更贴近日常、能被真人感知"的 P1:主机/端口规则 + 每连接日志。API 上轮不稳,
这轮**自己顺序作者每个 PR**(可靠),CI 仍逐个把关、绿了 merge。

**Feature A — 细粒度规则(进程 × 主机 × 端口)**
- **PR #11 引擎(端到端,无 UI)**:`Core.ProxyMatchRule` 模型 + `AppState.rules` + add/remove/reorder
  action + `Effect.applyRuleSet`;`IPCContract.MatchRuleDTO`;`EngineKit.RuleMatcher` + 零依赖 `Glob`
  (贪心 `*` 通配,`*.x` 只子域、`*x` 含 apex)对 DTO 求值(20 测试);`AppliedRuleSetStore` 全量替换
  + 评估;`AppFeature.RuleSetMapping`;App 发 applyRuleSet;扩展 effectiveRule 评估规则表。
  **顺带修了个既存真 bug**:每进程规则改动和全局开关此前根本没下发到扩展(没人 emit/send
  applyRuleSet),"设为代理"其实端到端不生效——现在真生效了。
- **PR #12 规则编辑 UI**:「规则表」tab,拖动排序 + 删除 + 添加表单(进程/主机 glob、端口空/单/区间、动作)。

**Feature B — 每连接日志**
- **PR #13 数据通路(端到端,无 UI)**:`IPCContract.ConnectionEventDTO` + `ExtensionToAppMessage.connectionEvent`;
  扩展每连接一个 `ConnectionContext`(锁保护字节 + 只发一次结束闸门),flow 建立发 opened、teardown 发
  closed/failed;`Core.ConnectionLogEntry` + `AppState.connectionLog`(上限 500)+ reducer 按 id upsert
  (opened→closed 原地更新);`AppFeature.ExtensionMessageHandling` 翻译。
- **PR #14 连接列表 UI**:「连接」tab,每条连接一行(进程 / 目标 host:port / 走向 / 状态点 / 字节),最新在前。

**架构决策记一笔**:规则**匹配器**放在 EngineKit 对 `MatchRuleDTO` 求值,而不是 Core——因为真正按
规则路由的是扩展,它经 EngineKit 工作,而 EngineKit 不能依赖 Core(不变量 B2)。Core 只放规则的**数据模型**
(给 AppState/UI 用),匹配逻辑在 EngineKit 重点测试。ConnectionLog 同理:Core 有 `ConnectionLogEntry`
数据模型,DTO 在 IPCContract,边界层 `ExtensionMessageHandling` 负责 DTO→Core 的穷举映射。

**过程**:又遇到几次"改 IPCContract enum → EngineKit `.build` 陈旧 → SIGSEGV",`rm -rf .build` 即好;
一次 commit 前忘 lint,推了带自定义规则(`optional_data_string_conversion`,要 `String(bytes:encoding:)`
而非 `String(decoding:as:)`)违规的版本,`--amend + --force-with-lease` 修掉。

**最终**:六个 PR(#11-#14 + 前面 #6-#10)全 CI 绿后 merge,247 个 SPM 测试全绿(Core 43 · IPCContract 10 ·
EngineKit 118 · AppFeature 65 · ArchitectureTests 11),`xcodebuild` Debug 零并发警告,swiftlint 零违规,codesign 通过。

**至此 Proxifier 对齐文档的 P0 + P1 全部清完**。仍在的遗留都是 P2 高级功能(代理链/故障转移/负载均衡——
已和用户确认:进程代理不必需,先不做)或需要人工的一次性步骤(系统扩展批准的两步),以及若干诚实小限制
(DNS-over-proxy 只在 app 用域名连时生效、UpstreamExclusion 纯文本不解析主机名、凭据未进 Keychain 前需重填——
已在 Keychain PR 解决、连接日志未持久化只在内存)。

## Phase 6：P2 高级路由（代理链 / 故障转移 / 负载均衡），两个顺序 PR

用户改主意，要补齐 P2（"补齐P2 高级功能，需要人工干预的case 留下回头我自测"）——所以 Phase 5
末尾"先不做 P2"那条作废。仍自己顺序作者每个 PR、CI 逐个把关。

**这三种模式各是什么（用户问过）**：
- **代理链 chain**：client → 上游1 → 上游2 → … → 目标。逐跳嵌套隧道：拨上游1，在这条 TCP 上对
  上游2 做握手（上游1 转发），再对上游3……最后对目标。全链复用**首跳那一条** NWConnection。
- **故障转移 failover**：按序尝试候选上游，第一台握手成功就用它，全失败抛最后一个错（fail-open 关流）。
- **负载均衡 loadBalance**：每条新连接在候选上游间轮询（RoundRobinSelector，游标跨 flow 存活）。

**PR-K（#15）模型 + IPC + 策略原语**：
- `Core.ProxyRoutingMode`(.single | .chain/.failover/.loadBalance([ProxyServerID])) + `AppState.proxyRoutingMode`
  + `setProxyRoutingMode` action + `Effect.applyRoutingMode`（独立消息，不动 applyProxyConfig 及其测试）。
- `IPCContract.ProxyRoutingModeDTO` + `AppToExtensionMessage.applyRoutingMode`。
- **EngineKit 策略原语（TDD 核心，全注入、零真实网络）**：`RoundRobinSelector`(actor)、`ChainConnector`
  (纯序列器，拨号+握手由注入的 hop 完成)、`FailoverConnector`(首个成功胜出)。9 测试。
- AppFeature 映射 + 持久化存/取模式（默认 .single 不重发）；App effectHandler 下发；扩展先只**存**模式。
  main 行为不变、保持绿。

**PR-L（#16）扩展多上游接线 + 路由模式 UI**：
- **`EngineKit.ProxyRouteResolver`（纯函数，TDD 15 测试）**：`(mode, servers, activeServerID) → ResolvedRoute`
  (.direct/.single/.chain/.failover/.loadBalance)。降级契约集中在这里：认不得的 id 丢掉、解析空了回落到
  单台 active、再没 active 就直连、链只剩一台 collapse 成 single。扩展现场只 switch 一个 ResolvedRoute。
- **`Extension/ProxyDialer`（无状态拨号）**：`ResolvedRoute + target → 已就绪的 NWConnection`。single 拨一台；
  failover 用 FailoverConnector 包 openSingleTunnel；loadBalance 轮询挑一台；chain 用 ChainConnector + chainHop
  （首跳新拨、后续复用 base 隧道），取首跳 NWConnectionByteStream 的底层连接当整条链的隧道。从 provider 拆出来
  是为了瘦身（type_body_length / file_length 两条 lint 触发过——拆完即消）。
- 扩展 `openRemote` 改为 resolve → ProxyDialer.open；连接日志的 proxyKind 取解析后路由首跳的 kind（直连记 nil）。
- **`AppFeature.RoutingModeKind` + `ProxyRoutingMode.togglingMember`（纯选择逻辑，8 测试）**：把带关联值的模式拍平成
  Picker 用的无参枚举，切种类保留已选 id 顺序，勾选按点击顺序进链。
- **UI**：`ProxyServersPaneView` 加「路由模式」区——分段选择器 + 每种模式一句说明 + 非 single 时列出上游让勾选
  （勾选顺序显示为编号，即链的跳序 / 故障转移的尝试序）。UI 只读 state、只 dispatch，逻辑全在已测的 AppFeature 助手。
- 持久化：`restorationActions`（含真机走的凭据回填变体）都带 `setProxyRoutingMode`，重启后恢复模式（各加了测试钉住）。

**架构决策记一笔**：路由**解析器**放 EngineKit（对 DTO 求值，不依赖 Core，守住 B2）；**拨号器** ProxyDialer 放
扩展（碰真实 NWConnection/NetworkExtension，不进 SPM 测试，守住 B4）；**选择器/种类映射**放 AppFeature（给 UI 用，
可测）。Core 只放 `ProxyRoutingMode` 数据模型。同 Phase 5 规则/日志的分层套路。

**最终**：PR-K/PR-L 全 CI 绿后 merge，288 个 SPM 测试全绿（Core 47 · IPCContract 11 · EngineKit 142 ·
AppFeature 77 · ArchitectureTests 11；相对 Phase 5 的 247：EngineKit +24（9 strategy + 15 resolver）、
AppFeature +12、Core +4、IPCContract +1），`xcodebuild` Debug 零并发警告，swiftlint --strict 零违规。

### ⚠️ 待人工自测（需真流量 / 需在系统设置点允许，loop 物理上做不了，回头自测回填）
这些是 API/系统决定的一次性人工步骤，不是没做：

1. **系统扩展批准**：装 app → 首次启动触发 NETransparentProxy 安装 → 「系统设置 → 隐私与安全性」点「允许」。
   （沿用 Phase 1 的 smoke-ne.sh：装扩展 → curl 走代理 → 打印观测到的进程身份级别。）
2. **代理链端到端**：配 ≥2 台真上游（如本地起两个 SOCKS5 / 一个 SOCKS5 + 一个 HTTP），选「代理链」，勾选顺序，
   用真流量确认逐跳穿通、且目标侧看到的是链尾出口。**待回填**：混合协议链（SOCKS5→HTTP→目标）握手时序是否稳。
3. **故障转移**：把候选里第一台设成连不上的地址，确认自动落到第二台；全down 时 fail-open（关流不卡其它流量）。
4. **负载均衡**：配 ≥2 台，发多条连接，确认在上游间轮转（可在两台上游侧看命中分布）。
5. **连接日志的 proxyKind 展示**：多台模式下日志里的协议标签取的是"首跳"，负载均衡实际选台逐连接轮转，
   标签是近似展示——真机确认是否需要改成"实际所用那台"（要的话让 ProxyDialer 把选中 kind 回传给事件）。

## Phase 7：对齐文档剩余 backlog · 批次 1（worktree 并行 agent + 我并行作者，4 个 PR）

用户要求把「优化(A)/补全(B)/高级(C)」的剩余项并行 TDD+PR 推进，需人工介入的测试只实现不执行、留作统一人工验证。
上一轮并行 agent 因**共享同一 checkout** 打架；这轮的优化 = **worktree 隔离** + 每个任务**互不重叠的文件**，
且 agent 只做 **SPM 包内可编译校验**的基础层（`swift test`+`swiftlint`，CI 正是只跑这两样），App/Extension 接线
与 `xcodebuild`（worktree 无签名配置）由我合并后集中做。

**并行 agent 产出的三个纯基础层（各自 worktree，只加新文件，零 enum/xcodebuild）：**
- **A2 · PR #18 `ProcessOriginExclusion`（EngineKit，12 测试）**：与基于地址的 `UpstreamExclusion` 正交的第二重转发环
  硬化——按**来源进程**判定:若一条 flow 由我们自己组件(app/扩展)发起,强制直连,别再被代理抓回来。纯 String/Set 谓词。
- **A3 · PR #19 `ConnectionLogFileStore`（AppFeature，7 测试）**：连接日志落盘(rolling JSONL),重启不丢;append/
  loadRecent/上限轮转/坏行跳过/缺文件→[],仿 `FilePersistenceStore` 的 Application Support + 吞错缓存语义。
- **C9 · PR #17 `TrafficStatsAggregator`（AppFeature，15 测试）**：全局流量的纯计算(总量 + Top-N + 双向吞吐率),
  确定性、无时钟读取(elapsed 传入),为将来菜单栏/全局统计 UI 打底。

**我并行作者的一个横切功能：**
- **B4 · PR #20 Block 拦截动作**：规则动作从 direct/proxied 补到三态,`.block` 命中即拒绝(扩展双向关流、不开远端,
  发一条 closed 事件让日志能看到「被拦截」;回环/上游排除仍优先,永不拦 localhost)。Core/IPCContract enum + 两处穷举
  映射 + matcher 透传 + 规则编辑器「拦截」选项 + 规则行/连接日志红色标签。跨 Core→IPC→EngineKit→Extension→UI,
  但只碰 agent 不碰的文件,故与三个 agent PR 全程无冲突。

**四个 PR 全 CI 绿后依次 merge，合并后集成复验**：324 个 SPM 测试全绿(Core 47 · IPCContract 11 · EngineKit 155 ·
AppFeature 100 · ArchitectureTests 11),`xcodebuild` Debug 零并发警告,`swiftlint --strict` 零违规(103 文件)。

**注意：A2/A3/C9 目前是「已合并但未接线」的基础层**（沿用本仓库 foundation-PR→wiring-PR 的既有分法）。待接线（我后续做，需 xcodebuild）：
- A2:扩展 `effectiveRule` 调 `ProcessOriginExclusion`,按 flow 的 `sourceAppSigningIdentifier` vs {APP/EXT bundle id} 强制直连
  （**依赖那条待人工回填**:自己 app 的 flow 到底以 bundle id 还是 team 前缀身份出现)。
- A3:App 把每条 connectionEvent 追加进 store、启动时 loadRecent 回灌 connectionLog。
- C9:菜单栏/统计视图接 `TrafficStatsAggregator`。

**仍未动的 backlog**（下一批次）：A1 UDP/QUIC(最大正确性缺口,需定策略:代理 UDP 还是先拦截止漏)、B5 单代理探活按钮、
B7 localhost 直连提升为可见设置(是否可关需产品决策——关掉有环/断本地开发风险)、C 高级(主动环检测弹窗/多 profile/
右键单连接指定代理/SOCKS4·NTLM·Kerberos/.dmp 抓包/便携版)、D 公证脚本补全(需你的公证凭据)。

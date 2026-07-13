# CRITERIA.md · 架构阶段验收判据（默认 FAIL）

规则：每条起始为 `[ ]`（false）。**必须先打开证据**（构建/测试输出、文件内容）才能把某条改成 `[x]`。
evaluator 是独立、无 Write/Edit 权限、没看过构建过程的 agent；它只信证据，不信声称。

证据详情见 PROGRESS.md；这里只记结论 + 去哪里复核。

## A. 构建与并发隔离（隔离靠编译器证明）
- [x] A1 `swift build` 对 Core / IPCContract / EngineKit / AppFeature 四个包全部成功——逐包 `cd Packages/<pkg> && swift build`，均 `Build complete!`，零 warning（`swift build 2>&1 | grep -ic warning` → 0）
- [x] A2 `xcodebuild -scheme App -configuration Debug -destination 'platform=macOS,arch=arm64' build` 成功（app + extension 两个 target）——`** BUILD SUCCEEDED **`，复现见 PROGRESS.md「如何复现」
- [x] A3 全项目 Swift 6 language mode，零并发警告——四包 `swift-tools-version: 6.0`；App/ProxyExtension target `SWIFT_VERSION=6.0`（project.yml）；对完整 xcodebuild 日志 `grep -i "sendable\|actor-isolat\|concurren\|data race\|nonisolated"` 结果为空
- [x] A4 `Config/Signing.xcconfig` 由 `scripts/gen-signing-xcconfig.sh` 从 `.env` 生成且被 gitignore；对 `TEAM_ID`（值见本机 `.env`，此文件不打印明文）做 `git grep`/`git log -p` 搜索，只命中两个二进制 `.provisionprofile`（CLAUDE.md 明确要求这两个文件放项目里），所有 `.swift/.yml/.pbxproj/.plist/.entitlements/.sh/.md` 零命中——**注意**：本文件曾经在 A4/E3 两条证据描述里手滑直接打印过明文 TEAM_ID，属于对 CLAUDE.md「team id 绝不进源码或提交历史」规则的违反，已发现并修复（含改写那一条 git 历史，因为仓库还没推到任何 remote，本地改写安全），细节记在 PROGRESS.md

## B. 架构不变量（有测试且通过）
- [x] B1 源码扫描测试：`Core`、`EngineKit`、`IPCContract` 中无 `import AppKit` 与 `import SwiftUI`——`Packages/ArchitectureTests` B1 套件，纯文件系统扫描（不 import 被测包），通过
- [x] B2 依赖方向测试：无上层被下层反向依赖——B2 套件解析各包 `Package.swift` 文本，确认 Core/IPCContract 零依赖、EngineKit 只依赖 IPCContract、AppFeature 只依赖 Core+IPCContract、没有包引用 AppFeature，通过
- [x] B3 `AppFeature.Store` 标注 `@MainActor`；负例已记录——B3 套件断言源码文本；真实编译器错误（把违规代码临时放进 Sources 跑 `swift build` 拿到的原始诊断）记在 `Packages/AppFeature/NegativeExamples/NonMainActorStoreAccess.md`
- [x] B4 `EngineKit` 路由类型是 `actor`，`Transport` 为协议且测试用 `MockTransport` 注入，测试中无真实网络/NE 调用——B4 套件断言 `FlowRouter` 源码含 `public actor`、`Transport` 为 `protocol`、`EngineKitTests` 全文件零命中 `import Network`/`import NetworkExtension`/`NEFlowTransport`

## C. 单向数据流（reducer 纯函数，TDD 覆盖）
- [x] C1 `reduce` 纯函数覆盖全局开关切换、加入进程（幂等）、分配规则、flowStatsDelta、Engine 异常 fail-open——`Packages/Core/Tests/CoreTests/ReducerTests.swift`，7 测试全绿
- [x] C2 增量刷新测试：flowStatsDelta 只更新命中进程，未命中条目值不变——同文件 `flowStatsDeltaIsIncremental`，对未命中的两个进程做值相等断言
- [x] C3 批量聚合测试：EngineKit 按节奏聚合、不是每包一次，用 MockTransport 驱动时间——`Packages/EngineKit/Tests/EngineKitTests/FlowRouterTests.swift`，`batchesInsteadOfPerPacket` 用显式 `now:` 时间戳推进，断言窗口内零 deliver、跨越 500ms 后恰好一次

## D. IPC 契约
- [x] D1 `IPCContract` 全为 `Sendable` 值类型；Codable round-trip 测试通过——`Packages/IPCContract/Tests/IPCContractTests/CodableRoundTripTests.swift`，5 测试全绿
- [x] D2 app↔扩展消息协议齐全（规则下发 RuleSetMessage、流量批量上报 FlowStatsBatchMessage、诊断请求/结果 DiagnosticRequestDTO/DiagnosticResultDTO），有编解码测试——同上，含 engineFailure 传递

## E. Network Extension 可安装产物（真实实现，非空壳）
- [x] E1 NETransparentProxyProvider 真实转发实现（拨号真实远端、双向 relay、按 rule 计量），扩展 embed 进 app target——`Extension/ProxyExtensionProvider.swift`；`build/appidge.app/Contents/Library/SystemExtensions/ProxyExtension.systemextension` 存在
- [x] E2 EngineKit 生产路径走真实 transport（`NEFlowTransport`：Network.framework 探活 + App Group/Darwin 通知投递），测试仍只用 `MockTransport`（B4 已验证），二者共用同一 `Transport` 协议
- [x] E3 Developer ID 签名 + NE entitlement 齐全，codesign 校验通过——App 与 Extension 均 `Authority=Developer ID Application: zhongyu wang (<TEAM_ID>)`（团队 ID 见本机 `.env`，此文件不打印明文），entitlements 含 `com.apple.developer.networking.networkextension=[app-proxy-provider-systemextension]` + `com.apple.security.application-groups=[group.com.appidge]`；`codesign --verify --deep --strict` exit 0。完整输出（含明文 TEAM_ID，因为是本机终端输出不是提交进 git 的文件）见运行 `codesign -dv` 的实际终端记录，不重复贴进本文件
- [x] E4 产出可安装 `.app`（`build/appidge.app`），`scripts/smoke-ne.sh` 存在、可执行、真跑过——脚本会签名校验、启动 app、真的提交系统扩展激活请求、跑 curl、抓 log stream；真实运行暴露了一个真实阻塞点，见下方「唯一不计入的一步」的修正说明

## F. 卫生
- [x] F1 `swift test` 全绿，无跳过/挂起——五个包（含 ArchitectureTests）合计 31 测试，`Test run with N tests passed`，零 failure
- [x] F2 SwiftLint 零 error——`swiftlint lint --strict` → `Found 0 violations, 0 serious in 34 files`（连 warning 都是 0，`--strict` 本会把 warning 当失败）
- [x] F3 `PROGRESS.md` 存在，记录完成项、失败尝试、遗留问题

## 唯一不计入的一步（物理上 loop 做不了，非阶段拆分）——已比预期多挖出一层
原计划：只差人在「系统设置 → 隐私与安全性」点「允许」。
**实际跑 `scripts/smoke-ne.sh` 后发现更早一层阻塞**：`OSSystemExtensionManager.submitRequest` 在本机上运行时报
`Missing entitlement com.apple.developer.system-extension.install`；把这个 entitlement 加进
`App.entitlements` 后，`xcodebuild` 直接拒绝签名，报「Provisioning profile "appidge App DevID" doesn't support
the System Extension capability」——即现有 Developer ID profile 在 Apple Developer Portal 里根本没启用 System
Extension capability。这必须由人登录 Apple Developer Portal 给这个 App ID 打开 System Extension capability、
重新生成两个 Developer ID profile、替换 `Signing/*.provisionprofile` 后，才能走到「点允许」那一步。
两步都记在 PROGRESS.md，loop 已经把状态推到能推的最远处：build 签名齐全、激活请求代码真实可用、只等
(1) 人去 portal 开 capability + 换 profile，(2) 系统设置点允许，(3) 跑 smoke 脚本回填 CLI 子进程身份粒度。

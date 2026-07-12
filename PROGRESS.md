# PROGRESS.md

## 状态：SPM 四包 + 架构不变量全绿；Xcode 工程/签名/NE 进行中

## 已完成（有绿测试证据，见 git log）

- `.env` / `.env.example` / `.gitignore` / `scripts/gen-signing-xcconfig.sh`：
  从 `.env` 生成 `Config/Signing.xcconfig`（gitignored），签名信息不进源码。
  验证过：跑通，输出正确的 DEVELOPMENT_TEAM / bundle id / profile UUID。
- **Core**（`Packages/Core`）：`ProcessID`/`FlowStats`/`FlowStatsDelta`/`ProxyRule`/
  `MonitoredProcess` 实体 + `AppState` + `Action` + `Effect` + 纯函数 `Reducer.reduce`。
  7 测试绿，覆盖全局开关、加入进程（幂等）、分配规则、flowStatsDelta 累加与增量性
  （未命中条目值不变）、未知 id 的 delta 被丢弃、engine 异常 fail-open。
- **IPCContract**（`Packages/IPCContract`）：`RuleSetMessage`（规则下发）、
  `FlowStatsBatchMessage`（流量批量上报）、`DiagnosticRequestDTO`/`DiagnosticResultDTO`
  （诊断请求/结果），包进 `AppToExtensionMessage`/`ExtensionToAppMessage` 信封。
  5 个 Codable round-trip 测试绿。零依赖（纯 wire contract）。
- **EngineKit**（`Packages/EngineKit`）：`Transport` 协议（`forward` 转发 + `deliver`
  推消息给 app 共用同一协议）；`FlowRouter` 是 `actor`，按 500ms 固定节奏批量聚合
  （不是每包一个 IPC），forward 异常 fail-open（重试 direct + 上报 engineFailure）；
  `MockTransport`（测试用，可配置失败）+ `NEFlowTransport`（生产真实实现：
  Network.framework 探活上游 + App Group/Darwin 通知推送）。4 测试绿，只依赖
  IPCContract。
- **AppFeature**（`Packages/AppFeature`）：`Store` 是 `@MainActor` + `@Observable`，
  `dispatch` 同步跑纯 reducer，副作用在 `Task.detached`（后台）跑，结果通过
  `@MainActor` 的 redispatch 闭包回灌 store。4 测试绿。**真实编译器错误证据**
  记录在 `Packages/AppFeature/NegativeExamples/NonMainActorStoreAccess.md`
  （曾把违规代码临时放进 Sources 跑 `swift build`，拿到真实诊断后删除）。
- **ArchitectureTests**（`Packages/ArchitectureTests`，测试专用第五个包，不计入
  CRITERIA A1 的四包）：纯文件系统/文本扫描（不 import 被测包），11 测试绿：
  - B1 Core/IPCContract/EngineKit 无 `import AppKit`/`import SwiftUI`
  - B2 依赖方向单向（Core/IPCContract 零依赖；EngineKit 只依赖 IPCContract；
    AppFeature 只依赖 Core+IPCContract；没有包反向依赖 AppFeature）
  - B3 `Store` 标注 `@MainActor` + 负例证据文件存在且含真实编译器错误文本
  - B4 `FlowRouter` 是 actor、`Transport` 是协议且有真实+mock 两个实现、
    EngineKitTests 不 import Network/NetworkExtension、不碰 NEFlowTransport

全部四包 + ArchitectureTests：`swift build` 逐包跑通，零警告；`swift test` 全绿
（合计 27 个测试：Core 7 + IPCContract 5 + EngineKit 4 + AppFeature 4 +
ArchitectureTests 11 = 31，上面数字以最新一次 `swift test` 输出为准）。

## 失败尝试 / 踩过的坑（别再试一遍）

1. `.env` 里 `DEVELOPER_ID_APPLICATION` 值原本没加引号（含冒号和括号），
   `sh -c '. ./.env'` 直接语法错误。**修复**：改成带双引号的值。以后任何
   含空格/特殊字符的 `.env` 值都必须加引号。
2. `AppFeature.Store.dispatch` 最初用 `Task.detached { [weak self] in ... await
   MainActor.run { self?.dispatch(...) } }`，Swift 6 报
   "sending 'self' risks causing data races"（task-isolated self 被送进
   MainActor-isolated 闭包）。**修复**：改成在 dispatch 内部先构造一个
   `@MainActor (Action) -> Void` 的 `redispatch` 闭包（只在这个闭包内 weak
   capture self），Task.detached 只捕获 `runEffect` 和 `redispatch`，不直接
   捕获 self。全局 actor 隔离的闭包类型本身是 Sendable，这样绕过了 region
   isolation 检查。
3. 本仓库不是 git repo 且没有全局 git user.name/email；已在仓库内本地设置
   （非 `--global`）`user.name=proxicat` `user.email=<用户邮箱>`，只影响这个
   仓库的 commit 身份。

## 遗留 / 下一步（Xcode 工程 + NE + 签名 + smoke，尚未开始或进行中）

- [ ] xcodegen 生成 App + Extension 两个 target 的 .xcodeproj，接 Config/Signing.xcconfig
- [ ] App target：菜单栏 + 主窗口三区骨架，只 observe AppFeature.Store
- [ ] Extension target：NETransparentProxyProvider 真实实现，委托给 EngineKit.FlowRouter
- [ ] Developer ID Application 签名 + NE entitlement + App Group，`codesign -dv` 校验
- [ ] `xcodebuild -scheme App -configuration Debug -destination 'platform=macOS,arch=arm64' build`
- [ ] `scripts/smoke-ne.sh`
- [ ] SwiftLint 配置 + 零 error
- [ ] **待人回填**：flow metadata 拿到 CLI 子进程（如 curl）级身份还是只到父 app 级——
      这需要人在「系统设置 → 隐私与安全性」点击「允许」批准系统扩展，并跑
      `scripts/smoke-ne.sh` 用真流量观测后填回本文件。loop 不会瞎猜这个答案。

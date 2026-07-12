# CRITERIA.md · 架构阶段验收判据（默认 FAIL）

规则：每条起始为 `[ ]`（false）。**必须先打开证据**（构建/测试输出、文件内容）才能把某条改成 `[x]`。
evaluator 是独立、无 Write/Edit 权限、没看过构建过程的 agent；它只信证据，不信声称。

## A. 构建与并发隔离（隔离靠编译器证明）
- [ ] A1 `swift build` 对 Core / IPCContract / EngineKit / AppFeature 四个包全部成功
- [ ] A2 `xcodebuild -scheme App -configuration Debug -destination 'platform=macOS,arch=arm64' build` 成功（app + extension 两个 target）
- [ ] A3 全项目在 **Swift 6 language mode** 下编译，**零并发（Sendable/actor-isolation）警告**——贴出 build log 中 concurrency 警告计数为 0 的证据
- [ ] A4 `Config/Signing.xcconfig` 由 env 生成且被 gitignore；`git log -p` / 源码中搜不到明文 `TEAM_ID` 值

## B. 架构不变量（有测试且通过）
- [ ] B1 源码扫描测试：`Core`、`EngineKit`、`IPCContract` 中无 `import AppKit` 与 `import SwiftUI`（列出扫描结果）
- [ ] B2 依赖方向测试/构建证明：无上层被下层反向依赖（Core 不依赖 AppFeature 等）
- [ ] B3 `AppFeature.Store` 标注 `@MainActor`；一个在非主 actor 触碰 state 会编译失败的负例被记录（说明隔离生效）
- [ ] B4 `EngineKit` 的路由类型是 `actor`，其 `Transport` 为协议且测试用 `MockTransport` 注入，测试中无真实网络/NE 调用

## C. 单向数据流（reducer 纯函数，TDD 覆盖）
- [ ] C1 `reduce` 为纯函数：给定 state+action 断言输出 state 与 Effect 列表，覆盖至少：全局开关切换、加入进程、分配规则、收到 flowStatsDelta、Engine 异常→fail-open 回直连
- [ ] C2 增量刷新测试：`flowStatsDelta` 只更新命中进程、不全量重算（用稳定 id 断言其余条目引用/值不变）
- [ ] C3 批量聚合测试：EngineKit 按节奏聚合计量后再产出批量 DTO（不是每包一次），用 MockTransport 驱动时间验证

## D. IPC 契约
- [ ] D1 `IPCContract` 全为 `Sendable` 值类型；DTO Codable round-trip 测试通过
- [ ] D2 app↔扩展消息协议定义齐全（至少：规则下发、流量批量上报、诊断请求/结果），有编解码测试

## E. Network Extension 可安装产物（真实实现，非空壳）
- [ ] E1 NETransparentProxyProvider 有真实转发实现，扩展 embed 进 app target
- [ ] E2 EngineKit 产物路径走真实 transport（测试仍用 MockTransport 注入），二者共用同一协议
- [ ] E3 Developer ID 签名 + Network Extension entitlement 齐全，`codesign -dv` / entitlement 校验通过（贴证据）
- [ ] E4 产出可安装 build（.app），`scripts/smoke-ne.sh` 存在且可执行（装扩展→curl 走代理→打印进程身份级别）

## F. 卫生
- [ ] F1 `swift test` 全绿，输出无跳过/挂起用例（贴 tail 结论）
- [ ] F2 SwiftLint（或 swift-format lint）零 error
- [ ] F3 `PROGRESS.md` 存在，记录完成项、失败尝试、遗留问题（尤其 CLI 子进程身份粒度待人跑 smoke 回填）

## 唯一不计入的一步（物理上 loop 做不了，非阶段拆分）
- 在系统设置点「允许」批准系统扩展 + 跑 smoke 脚本用真流量观测 flow metadata 身份级别 —— 需人点一下 + 真实网络。loop 把状态推到「就差这一下」即算达标。

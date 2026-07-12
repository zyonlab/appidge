# CLAUDE.md · macOS 按进程代理 · 架构阶段（Phase 1）

本文件是长跑计划，保持在 context。你可以边做边改它、为后续 session 更新。
本阶段**只做架构骨架，不做业务功能**。功能分阶段（见文末），本轮 `/goal` 只收敛架构。

---

## 0. 每个 session 开工前先做（顺序不可乱）

> 单条 `/goal` 即可起跑：你起手**必须自己按本节 1→4 铺好地基再进收敛**，不要停下来问我。缺信息就报错停；能推进就一路推进到 CRITERIA 全绿，卡住记 PROGRESS.md 换路子，别空转。

1. **先从 `.env` 读环境变量**，缺必需项就立刻报错停下，绝不硬编码签名信息：
   - 若无 `.env`：从 `.env.example` 复制一份并报错提示我填，然后停下。`.env` 必须在 `.gitignore` 里，`.env.example` 提交但只放占位值。
   - 必需：`TEAM_ID`、`DEVELOPER_ID_APPLICATION`、`APP_BUNDLE_ID`、`EXT_BUNDLE_ID`、`APP_GROUP`、`PROFILE_APP`、`PROFILE_EXT`
   - 可选：`SIGN_IDENTITY`（默认取 `DEVELOPER_ID_APPLICATION`）、`BUNDLE_ID_PREFIX`
   - source `.env` 后写进 git-ignore 的 `Config/Signing.xcconfig`（Xcode 只认 xcconfig，不认 .env）。代码/工程只引用 xcconfig，team id 绝不进源码或提交历史。
   - 校验 `PROFILE_APP`/`PROFILE_EXT` 指向的两个 `.provisionprofile` 真实存在，缺了就报错停。
   ```bash
   set -a; [ -f .env ] || { cp .env.example .env; echo "填好 .env 再跑"; exit 1; }; . ./.env; set +a
   : "${TEAM_ID:?}"; : "${DEVELOPER_ID_APPLICATION:?}"; : "${APP_BUNDLE_ID:?}"; : "${EXT_BUNDLE_ID:?}"; : "${APP_GROUP:?}"
   [ -f "$PROFILE_APP" ] && [ -f "$PROFILE_EXT" ] || { echo "缺 provisionprofile"; exit 1; }
   ```
2. `cat PROGRESS.md`（没有就创建），确认上一轮进度、已知失败尝试、剩余任务。
3. `cat CRITERIA.md`，明确本轮验收判据（默认全 FAIL，你不打开证据不许标 pass）。
4. **搭工程骨架**（首轮若尚未存在）：SPM + Xcode 工程，Core / IPCContract / EngineKit / AppFeature 四个包 + App 与 Extension 两个 target；主 app bundle=`$APP_BUNDLE_ID`、扩展 bundle=`$EXT_BUNDLE_ID`（须为主 app 子级）、共享 `$APP_GROUP`；开 **Swift 6 language mode**；两个 target 开发期用「Automatically manage signing」（Apple Development），Developer ID profile 仅出包时用。骨架能 `swift build` + `swift test` 跑通后，直接进入 TDD 收敛，不停下等确认。

---

## 1. TDD 纪律（红-绿-重构，每步可提交）

- **先写失败测试，再写实现**。禁止无测试的实现代码进 Core / EngineKit / AppFeature。
- 每个「有意义的绿」就 commit + push；commit message 说清做了什么。
- **每次 commit 前**跑 `swift test 2>&1 | tail -40` 和架构不变量测试，全绿才提交。
- **绝不提交会破坏现有通过测试的代码。** 卡住时把失败尝试记进 PROGRESS.md，不要反复试同一个死路。
- 测试输出量要小：详细日志重定向到文件，context 里只留结论几行。

---

## 2. 架构（UI 与数据分离 + 单向事件驱动 + 线程隔离）

分包，依赖方向单向向下，**上层不许反向依赖**：

```
Core          领域层：纯 Swift，零 AppKit/SwiftUI。实体 + Action + State + Reducer(纯函数)
IPCContract   app↔扩展的 Sendable DTO 与消息协议（纯值类型，Codable）
EngineKit     actor 化转发/路由骨架；FlowRouter；Transport 协议 + MockTransport
AppFeature    @MainActor 单向 store：@Observable State，dispatch(Action)→reduce→Effect
─────────────
App target        menu bar + 主窗口三区(目录/规则/活动监视器)，只 observe store、只 dispatch action
Extension target  NETransparentProxyProvider 薄壳，委托给 EngineKit（本阶段不深测，见闸门）
```

**单向数据流规则（event-drive）：**
- UI 只做两件事：读 State、`dispatch(Action)`。UI 里禁止直接改 State、禁止直接发网络。
- `reduce(state, action) -> (State, [Effect])` 是**纯函数**，无副作用、可单测。
- 副作用只在 Effect 里、只在后台执行，结果以新的 Action 回灌 store。
- 扩展来的流量统计、诊断结果，都作为 Action 进 store，UI 被动刷新。

**线程隔离规则（用编译器强制，不靠自觉）：**
- 全项目开 **Swift 6 language mode**（strict concurrency complete）。目标是零并发警告。
- `AppFeature` store 是 `@MainActor`；所有 UI 可见状态变更只在主 actor。
- `EngineKit` 的路由/计量是 `actor`，跑在主线程之外；对外只暴露 `Sendable` 类型。
- 跨 app↔扩展边界的一切都走 `IPCContract` 的 `Sendable` DTO，禁止共享可变引用。

---

## 3. 性能与体验底线（架构阶段就要立住的接口）

- 活动监视器面板会高频刷新（每进程实时上下行）。store 不能每条流量都全量重算：Action 设计成**增量**（`flowStatsDelta`），reduce 走 diff，UI 用稳定 id 做局部刷新。
- Engine 侧计量在 actor 内累加，**按固定节奏批量**推给 app（如 500ms 聚合一次），不要每包一个 IPC。这条要在 EngineKit 的接口签名里体现（批量 DTO），本阶段用 MockTransport 验证聚合逻辑。
- 安全兜底是架构约束不是功能：Engine 异常路径默认 **fail-open**（恢复直连），骨架里就要有这个分支和它的测试。

---

## 4. Network Extension：直接做全，不拆阶段

一次做到「可安装」：NETransparentProxyProvider 真实实现（不是空壳）、EngineKit 用真实 transport 转发（同时保留 MockTransport 供测试注入）、扩展 embed 进 app、Developer ID 签名 + entitlement 齐全、产出能装的 build。

- Engine 对外接口对真实 transport 与 MockTransport 都成立（协议注入）：单测走 mock，产物走真实。
- **唯一 loop 物理上做不了的一步**：在「系统设置 → 隐私与安全性」点「允许」批准系统扩展 + 用真流量观测 flow metadata 的进程身份级别。这需要人点一下 + 真实网络，不是我要拆阶段，是 API 决定的。
  - 所以 loop 必须做到：产出**已签名、可安装**的 build，**外加** `scripts/smoke-ne.sh`（装扩展 → 发一条 curl 走代理 → 打印观测到的进程身份级别），把状态推到「就差人点允许」。
  - PROGRESS.md 记一条待人回填：flow metadata 拿到 CLI 子进程（如 curl）级身份还是只到父 app 级——人跑完 smoke 脚本填，loop 不许瞎猜。

---

## 5. 后续功能阶段（架构+NE 做完后可续，勿提前动手）

- 目录扫描 + 行业种子打标（薪资倒排）+ 规则表 + 回环排除
- 活动监视器面板接真 Engine + 每行代理开关/诊断入口
- 诊断器（规则命中/是否真走代理/上游可达/DNS/UDP/IPv6·QUIC 泄漏/env 冲突）
- 首次安装引导 + 状态持久化 + 打包公证

# B3 负例证据：非主 actor 触碰 Store.state 编译失败

`Store` 标注 `@MainActor`（见 [`Sources/AppFeature/Store.swift`](../Sources/AppFeature/Store.swift)）。
以下代码曾被临时放进 `Sources/AppFeature/_TEMP_NegativeExample.swift` 并跑
`swift build` 验证，然后删除——本文件记录复现步骤与实际拿到的编译器诊断，
证明隔离确实生效，不是靠自觉。

## 复现步骤

```bash
cd Packages/AppFeature
cat > Sources/AppFeature/_TEMP_NegativeExample.swift <<'EOF'
import Core

actor RogueBackgroundWorker {
    func mutateStateFromBackground(_ store: Store) {
        let snapshot = store.state
        _ = snapshot
    }
}
EOF
swift build
rm Sources/AppFeature/_TEMP_NegativeExample.swift
```

## 实际拿到的诊断（Swift 6 language mode，2026-07-13）

```
/Users/admin/appidge/Packages/AppFeature/Sources/AppFeature/_TEMP_NegativeExample.swift:5:30: error: main actor-isolated property 'state' can not be referenced on a nonisolated actor instance
3 | actor RogueBackgroundWorker {
4 |     func mutateStateFromBackground(_ store: Store) {
5 |         let snapshot = store.state
  |                              `- error: main actor-isolated property 'state' can not be referenced on a nonisolated actor instance
6 |         _ = snapshot
7 |     }

/Users/admin/appidge/Packages/AppFeature/Sources/AppFeature/Store.swift:10:29: note: property declared here
 8 | @Observable
 9 | public final class Store {
10 |     public private(set) var state: Core.AppState
   |                             `- note: property declared here
11 |     private let effectHandler: @Sendable (Core.Effect) async -> Core.Action?
12 |
```

编译按预期失败——一个非隔离的 `actor` 直接读 `store.state` 会被 Swift 6
strict concurrency 拒绝，证明 `@MainActor` 隔离在编译期生效，而非仅靠约定。

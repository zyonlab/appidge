import Foundation

/// 连接日志相关的 reduce 实现,从 Reducer.swift 拆出(压 file_length,同 ReducerMatchRules.swift
/// 的既有先例)。跨文件访问,故这里的方法为 internal(非 private)。
extension Reducer {
    /// 按连接 id 去重更新:已有则原地更新那一行(不重排、不占新名额),否则追加;
    /// 超过 ``AppState/connectionLogCap`` 就丢最旧。顺带把这条连接的进程注册进
    /// `state.processes`(若之前没见过)——"应用"表现在展示的是**真实观察到过连接的进程**,
    /// 不再局限于目录扫描到的 app(同 `directoryScanned`/`processDiscovered` 的幂等写法:
    /// 已存在就不碰,避免覆盖扫描/持久化已经取到的更好的 displayName/已分配的 rule)。
    static func connectionEventReceived(_ entry: ConnectionLogEntry, _ state: AppState) -> (AppState, [Effect]) {
        (applyingConnectionEntry(entry, to: state), [])
    }

    /// 一批连接事件在**一次** reduce 里全部落地(app 侧 IPCReceiver 按固定节奏合并推来)——
    /// 单次 state 变更 → 昂贵的连接表只重渲染一次,重渲染频率与事件速率解耦(与扩展侧
    /// flowStats 批量推送同一套架构思路)。语义与逐条 `connectionEventReceived` 完全一致,
    /// 只是把 N 次 @Observable 失效压成 1 次。
    static func connectionEventsReceived(
        _ entries: [ConnectionLogEntry], _ state: AppState
    ) -> (AppState, [Effect]) {
        var state = state
        for entry in entries {
            state = applyingConnectionEntry(entry, to: state)
        }
        return (state, [])
    }

    /// 按连接 id 去重更新:已有则原地更新那一行(不重排、不占新名额),否则追加;
    /// 超过 ``AppState/connectionLogCap`` 就丢最旧。顺带把这条连接的进程注册进
    /// `state.processes`(若之前没见过)——"应用"表现在展示的是**真实观察到过连接的进程**,
    /// 不再局限于目录扫描到的 app(同 `directoryScanned`/`processDiscovered` 的幂等写法:
    /// 已存在就不碰,避免覆盖扫描/持久化已经取到的更好的 displayName/已分配的 rule)。
    static func applyingConnectionEntry(_ entry: ConnectionLogEntry, to state: AppState) -> AppState {
        var state = state
        // 从**尾部**找:日志按插入顺序排列,而绝大多数更新打的是刚刚建立的那条连接
        // (opened → 统计 → closed),它就在尾部附近 —— 倒着找命中通常是 O(1),正着找则每次都要
        // 从最老的一条扫起。id 在日志里唯一(本函数即按 id 去重),所以 first/last 找到的是
        // **同一个元素**,语义完全等价,没有行为变化。
        if let index = state.connectionLog.lastIndex(where: { $0.id == entry.id }) {
            // 迟到的 `.opened` 回填绝不复活已关闭的行:扩展对活跃连接周期性重发 .opened 回填字节,
            // Task 投递无序,关闭事件可能先落地——已 closed/failed 的行整行保留(关闭时的字节是
            // 最终值,必然 ≥ 迟到快照),否则该行会永远显示"活动"绿点。
            let existing = state.connectionLog[index]
            if entry.phase == .opened, existing.phase != .opened {
                return state
            }
            state.connectionLog[index] = entry
        } else {
            state.connectionLog.append(entry)
            if state.connectionLog.count > AppState.connectionLogCap {
                state.connectionLog.removeFirst(state.connectionLog.count - AppState.connectionLogCap)
            }
        }
        if state.processes[entry.processID] == nil {
            state.processes[entry.processID] = MonitoredProcess(
                id: entry.processID,
                displayName: entry.processDisplayName ?? entry.processID.value,
                executablePath: entry.processID.value
            )
        }
        return state
    }

}

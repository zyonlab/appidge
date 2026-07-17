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
        if let index = state.connectionLog.firstIndex(where: { $0.id == entry.id }) {
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

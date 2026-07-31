import Foundation
import Core
import AppFeature

/// 每小时的授权时钟推进循环:本地判定宽限耗尽/订阅到期(防时钟回拨),到期则触发每日联网
/// 校验。从 `AppidgeApp` 的 `.task` 拆出的独立命名空间。
///
/// 幂等闸与 `EnvironmentSignals.periodicRefreshTask` 同款同因:调用点在主窗口 `.task` 里,
/// 循环是游离 Task、不随视图取消——窗口关了再开会重跑 `.task`,没有闸每次重开就多叠一路
/// 时钟(= 多一路每日校验触发源)。
enum LicenseClock {
    @MainActor private static var tickTask: Task<Void, Never>?

    /// 启动每小时 tick(重复调用幂等)。
    @MainActor
    static func startHourlyTicks(store: Store) {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000) // 1 小时
                let now = Date()
                store.dispatch(.licenseClockTick(now: now))
                if store.state.isValidateDue(now: now) {
                    store.dispatch(.licenseValidateRequested(now: now))
                }
            }
        }
    }
}

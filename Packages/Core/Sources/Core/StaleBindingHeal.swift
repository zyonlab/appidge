import Foundation

/// 「升级后会话绑死旧 provider = 全系统黑洞」的自愈**决策**。
///
/// 反复热升级后，系统可能把流量仍然交给待卸载的旧 provider 实例：会话看着是连着的，
/// 但新 provider 收不到任何 flow —— 表现为「打开应用后没有活动连接」，严重时全系统断网。
///
/// 这里只做**判定**，不做副作用（重启接管由 App 层执行）。纯函数 + 幂等，可被安全地反复评估：
/// 这正是修复的关键 —— 原实现只在「扩展回报版本」这一个事件边沿上触发一次，
/// 而那个事件常常早于观察者接线（详见 ``StaleBindingHealMemo``）。
public enum StaleBindingHealDecision: Sendable, Equatable {
    /// 无需动作。
    case none
    /// 运行版本 != 包内版本 = 会话绑在旧 provider 上：做一次**有界**强制重启，逼 NE 换到最新 provider。
    /// 只做一次——防「旧 provider 本身有 bug」时陷入无限重启环，仍留手动「重启接管」兜底。
    case scheduleForcedRestart
    /// 曾见不匹配、现在版本已一致：重绑一次，让会话真正挂到新 provider 上。
    case rebindNow
}

/// 自愈的一次性记忆。App 层持有，跨多次评估累积，保证「强制重启」「重绑」各自最多发生一次。
///
/// **为什么必须允许反复评估**：自愈原先只挂在 `.extensionVersionReported` 这个 action 边沿上，
/// 而扩展 XPC 一连上就发版本，往往早于 App 侧观察者接线；且该 action 有去重，
/// 扩展再报同一版本也不会重新触发 —— 于是升级后那唯一一次需要自愈的启动被永久错过。
/// 把判定做成「读当前 state + memo」的纯函数后，App 层可以在任意时机安全地补评估。
public struct StaleBindingHealMemo: Sendable, Equatable {
    /// 是否曾观察到「运行版本 != 包内版本」。
    public var sawMismatch: Bool
    /// 是否已经做过那一次有界强制重启。
    public var forcedRestartAttempted: Bool
    /// 是否已经做过升级后的那一次重绑。
    public var rebound: Bool

    public static let initial = StaleBindingHealMemo(
        sawMismatch: false, forcedRestartAttempted: false, rebound: false
    )

    public init(sawMismatch: Bool, forcedRestartAttempted: Bool, rebound: Bool) {
        self.sawMismatch = sawMismatch
        self.forcedRestartAttempted = forcedRestartAttempted
        self.rebound = rebound
    }

    /// 把一次决策记进 memo。`.none` 不消耗任何一次性额度——否则相位还没落定时的那次
    /// 「不动作」评估会把额度吃掉，导致相位落定后再也不自愈（正是原缺陷的第二层）。
    public mutating func recordDecision(_ decision: StaleBindingHealDecision) {
        switch decision {
        case .none:
            break
        case .scheduleForcedRestart:
            sawMismatch = true
            forcedRestartAttempted = true
        case .rebindNow:
            rebound = true
        }
    }
}

extension AppState {
    /// 依据当前版本握手结果与 `memo`，判定是否需要自愈陈旧的 provider 绑定。
    ///
    /// 前置条件（任一不满足即 `.none`）：
    /// - 功能已开放（``isLicenseActive``）且已完成引导 —— 否则本就不该有会话在跑；
    ///   注意这两项是**异步**落定的，所以必须允许稍后重新评估，不能只在启动瞬间判一次。
    /// - 运行版本与包内版本都已知 —— 不确定就不误重启接管（``extensionNeedsRebind`` 的语义）。
    public func staleBindingHealDecision(memo: StaleBindingHealMemo) -> StaleBindingHealDecision {
        guard isLicenseActive, hasCompletedOnboarding else { return .none }
        guard runningExtensionVersion != nil, bundledExtensionVersion != nil else { return .none }

        if extensionNeedsRebind {
            return memo.forcedRestartAttempted ? .none : .scheduleForcedRestart
        }
        // 版本已一致：只有「曾经见过不匹配」才需要补一次重绑；正常启动不该无谓重启接管。
        guard memo.sawMismatch, !memo.rebound else { return .none }
        return .rebindNow
    }
}

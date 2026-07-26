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
    /// 新版本卡在「待重启电脑生效」：**重启隧道是徒劳的**——`restart()` 用版本无关的
    /// `providerBundleIdentifier`，改不了系统注册哪个版本。唯一能换版本的是重新提交
    /// `OSSystemExtensionRequest`（并先释放旧 provider 的占用，给替换一次不用重启就完成的机会）。
    case reactivateExtension
    /// 扩展在跑但 XPC 通道不可达（监听器注册失败的竞态,2026-07-26 真机实锤）：重启接管一次。
    /// 与版本自愈**独立触发**——注册失败时握手根本到不了,`runningExtensionVersion` 永远 nil,
    /// 版本判据对这类故障失明。配合扩展侧「自检失败 + sessionless 即 exit」,stop→start 的窗口
    /// 让坏进程退出重生,新进程重新注册 mach service,闭环恢复。
    case restartForUnreachableChannel
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
    /// 是否已经为「待重启生效」重新提交过一次 activation。
    public var reactivateAttempted: Bool
    /// 是否已经为「XPC 通道不可达」重启过一次接管。
    public var channelRestartAttempted: Bool

    public static let initial = StaleBindingHealMemo(
        sawMismatch: false, forcedRestartAttempted: false, rebound: false, reactivateAttempted: false
    )

    public init(sawMismatch: Bool, forcedRestartAttempted: Bool, rebound: Bool,
                reactivateAttempted: Bool = false, channelRestartAttempted: Bool = false) {
        self.sawMismatch = sawMismatch
        self.forcedRestartAttempted = forcedRestartAttempted
        self.rebound = rebound
        self.reactivateAttempted = reactivateAttempted
        self.channelRestartAttempted = channelRestartAttempted
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
        case .reactivateExtension:
            sawMismatch = true
            reactivateAttempted = true
        case .restartForUnreachableChannel:
            channelRestartAttempted = true
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
        // **通道可达性先于版本判据**：监听器注册失败时 XPC 根本连不上，`runningExtensionVersion`
        // 永远 nil（或是断开前的陈旧值）——版本自愈对这类故障失明。扩展在跑、通道却不可达，
        // 就重启接管一次（一次为限，防重生后仍失败的无限环）；不可达期间**不落入**版本自愈，
        // 陈旧的版本数据不足以支撑 reactivate/强制重启，等通道恢复、数据新鲜了再判。
        if !isXPCChannelReachable, extensionActivation.isRunning {
            return memo.channelRestartAttempted ? .none : .restartForUnreachableChannel
        }
        guard runningExtensionVersion != nil, bundledExtensionVersion != nil else { return .none }

        if extensionNeedsRebind {
            // **判据是版本不匹配本身，不是 activation 报了什么**。
            // 曾经把「重新提交 activation」绑在 `isPendingReboot` 上，结果真机 75→77 升级时
            // activation 报的是 `.completed`（UI 显示「已接管」），系统却仍在跑旧 provider ——
            // 于是落到只重启隧道那条，而隧道重启用的是版本无关的 providerBundleIdentifier，
            // **改不了系统注册哪个版本**，自愈跑了也白跑。
            //
            // 不匹配就是「系统在跑旧 provider」的事实真相：先重新提交 activation（唯一能换版本的
            // 手段），不行再退回有界强制重启作第二手，各一次为限，之后留手动「重启接管」兜底。
            if !memo.reactivateAttempted { return .reactivateExtension }
            return memo.forcedRestartAttempted ? .none : .scheduleForcedRestart
        }
        // 版本已一致：只有「曾经见过不匹配」才需要补一次重绑；正常启动不该无谓重启接管。
        guard memo.sawMismatch, !memo.rebound else { return .none }
        return .rebindNow
    }
}

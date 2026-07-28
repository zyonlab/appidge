import Foundation

/// 「设置类」action 的 reduce,从 Reducer.swift 拆出(压 file_length,同 ReducerMatchRules 先例)。
/// 跨文件访问,故为 internal(非 private)。
extension Reducer {
    static func reduceSettings(_ state: AppState, _ action: Action) -> (AppState, [Effect])? {
        switch action {
        case .loopWarningRaised(let signature, let processID, let executablePath):
            return loopWarningRaised(signature, processID: processID, executablePath: executablePath, state)
        case .loopAutoExclusionsRestored(let restored):
            return loopAutoExclusionsRestored(restored, state)
        case .dismissLoopWarning:
            return dismissLoopWarning(state)
        case .resetState:
            // 切档案清运行时/会话状态，但**授权与网络接管解耦**：license 是账号级、非档案级，
            // profile 切换不该把付费状态清掉（Keychain 里那份也还在）。故 license 相位/记录原样带过。
            var fresh = AppState()
            fresh.licensePhase = state.licensePhase
            fresh.license = state.license
            // 试用同样是账号/安装级、非档案级：切档案不重置试用进度与配置。
            fresh.trialConfig = state.trialConfig
            fresh.trial = state.trial
            // 落定标记跟随相位带过——切档案不该让授权门在会话中途再闪一次。
            fresh.isLicensePhaseResolved = state.isLicensePhaseResolved
            return (fresh, [])
        case .setPacketCaptureEnabled(let enabled):
            var state = state
            state.isPacketCaptureEnabled = enabled
            return (state, [.applyPacketCapture(enabled)])
        case .setUDPPolicy(let policy):
            var state = state
            state.udpPolicy = policy
            return (state, [.applyUDPPolicy(policy)])
        case .extensionActivationChanged(let activation):
            return extensionActivationChanged(activation, state)
        case .proxyProcessIdentitiesResolved(let discovery):
            return proxyProcessIdentitiesResolved(discovery, state)
        default:
            return nil
        }
    }

    /// 运行时信号(代理环境探测 / 扩展版本握手)——纯状态回灌,无副作用。拆成独立一组,
    /// 让 `reduceSettings` 的分支数保持在 cyclomatic_complexity 阈值内。
    static func reduceRuntimeSignals(_ state: AppState, _ action: Action) -> (AppState, [Effect])? {
        switch action {
        case .proxyEnvironmentDetected(let environment):
            guard state.proxyEnvironment != environment else { return (state, []) }
            var state = state
            state.proxyEnvironment = environment
            return (state, [])
        case .extensionVersionReported(let version):
            guard state.runningExtensionVersion != version else { return (state, []) }
            var state = state
            state.runningExtensionVersion = version
            return (state, [])
        case .bundledExtensionVersionSet(let version):
            guard state.bundledExtensionVersion != version else { return (state, []) }
            var state = state
            state.bundledExtensionVersion = version
            return (state, [])
        case .xpcChannelReachabilityChanged(let reachable):
            guard state.isXPCChannelReachable != reachable else { return (state, []) }
            var state = state
            state.isXPCChannelReachable = reachable
            return (state, [])
        case .configurationReplayCompleted:
            guard !state.isConfigurationReplayComplete else { return (state, []) }
            var state = state
            state.isConfigurationReplayComplete = true
            return (state, [])
        default:
            return nil
        }
    }

    /// 扩展(重新)跑起来 = 新的引擎会话:之前 fail-open 标记的不健康态就此翻篇,恢复健康并把
    /// 真实规则集重推下去(不健康期间推的是空规则集)。只在「不健康 → active」转变沿推一次。
    static func extensionActivationChanged(_ activation: ExtensionActivation, _ state: AppState) -> (AppState, [Effect]) {
        var state = state
        state.extensionActivation = activation
        if case .active = activation, !state.isEngineHealthy {
            state.isEngineHealthy = true
            return (state, [ruleSetPush(state)])
        }
        return (state, [])
    }

    /// 端口发现结果整体替换 `dynamicOriginExclusion`(环自愈的 `loopAutoExclusions` 独立保留,
    /// 下发取并集)。未变化就不推(幂等守卫,同其它下发)。
    static func proxyProcessIdentitiesResolved(
        _ discovery: OriginExclusionDiscovery, _ state: AppState
    ) -> (AppState, [Effect]) {
        guard state.dynamicOriginExclusion != discovery else { return (state, []) }
        var state = state
        state.dynamicOriginExclusion = discovery
        return (state, [state.originExclusionsPush])
    }

    /// 环检测自愈 + 告警:
    /// 1. 把触发 flow 的来源进程双信号并进 `loopAutoExclusions` 并回推扩展——来源进程从此
    ///    硬旁路,环当场断掉(对齐 Proxifier「检测到环 → 自动建该进程 Direct 置顶规则」)。
    ///    已收录过则不重推(幂等)。自愈不受「忽略」影响:忽略只是不想再看见横幅。
    /// 2. 弹告警条;用户已「忽略」过的 signature 不再重复弹(扩展侧检测器每次命中都会投递)。
    static func loopWarningRaised(
        _ signature: String, processID: ProcessID?, executablePath: String?, _ state: AppState
    ) -> (AppState, [Effect]) {
        var state = state
        var effects: [Effect] = []

        var exclusions = state.loopAutoExclusions
        // a.out 一类无法区分软件的标识不进 identifier 集(会连坐所有未签名 CLI),只收路径信号。
        if let processID, !OriginExclusionDiscovery.isAmbiguousIdentifier(processID.value) {
            exclusions.identifiers.insert(processID.value)
        }
        if let executablePath { exclusions.executablePaths.insert(executablePath) }
        if exclusions != state.loopAutoExclusions {
            state.loopAutoExclusions = exclusions
            effects.append(state.originExclusionsPush)
        }

        if !state.dismissedLoopSignatures.contains(signature) {
            state.loopWarning = signature
        }
        return (state, effects)
    }

    /// 启动恢复:持久化的环自愈排除并集灌回。**并集而非替换**——恢复可能晚于本次运行已学到的
    /// 新条目(理论窗口),不能把它们冲掉。入集前同样过 a.out 歧义滤网(与 `loopWarningRaised`
    /// 的学习路径同一条政策,防旧盘面数据把未签名 CLI 连坐进来)。有真实变化才回推扩展(幂等)。
    static func loopAutoExclusionsRestored(
        _ restored: OriginExclusionDiscovery, _ state: AppState
    ) -> (AppState, [Effect]) {
        var merged = state.loopAutoExclusions
        merged.identifiers.formUnion(
            restored.identifiers.filter { !OriginExclusionDiscovery.isAmbiguousIdentifier($0) }
        )
        merged.executablePaths.formUnion(restored.executablePaths)
        guard merged != state.loopAutoExclusions else { return (state, []) }
        var state = state
        state.loopAutoExclusions = merged
        return (state, [state.originExclusionsPush])
    }

    /// 关闭当前告警并记住它的 signature——同一问题不再打扰;重启后清零(运行时状态)。
    static func dismissLoopWarning(_ state: AppState) -> (AppState, [Effect]) {
        var state = state
        if let signature = state.loopWarning {
            state.dismissedLoopSignatures.insert(signature)
        }
        state.loopWarning = nil
        return (state, [])
    }
}

extension MonitoredProcess {
    /// 累计字节只增不减;瞬时速率 = 本批增量 ÷ 本批时间窗。时间窗非正时只累计、不动速率
    /// (调用方已把速率归 0)。
    mutating func apply(_ delta: FlowStatsDelta, intervalSeconds: Double) {
        stats.apply(delta)
        guard intervalSeconds > 0 else { return }
        rateUpPerSec = Double(delta.bytesUpDelta) / intervalSeconds
        rateDownPerSec = Double(delta.bytesDownDelta) / intervalSeconds
    }
}

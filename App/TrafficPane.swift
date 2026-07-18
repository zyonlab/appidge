import SwiftUI
import AppKit
import Core
import AppFeature

/// 主窗口「活动」底部面板:**可折叠事件日志**(对齐 Proxifier 的 Log 面板 / 苹果 Console.app)。
/// 取代旧的带宽曲线——遍历 `store.state.connectionLog`,每行一条事件(时间 · 进程 · → 目标 · 走法 · 状态)。
/// 头部带折叠三角 + 「日志 N」计数 + 「清除」+「在访达中显示」(打开磁盘日志目录)。
/// 走法胶囊复用连接表的 ``RouteChip`` / ``RouteText``,保证路由呈现一致。
struct TrafficPane: View {
    var store: Store
    @State private var expanded = true

    /// 事件日志按时间倒序(最新在前),与连接表默认排序一致。
    private var events: [ConnectionLogEntry] {
        store.state.connectionLog.sorted { $0.openedAt > $1.openedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if expanded {
                if events.isEmpty {
                    emptyState
                } else {
                    logList
                }
            }
        }
        .background(.background)
    }

    /// 折叠头:三角 + 标题 + 计数徽标,右侧「在访达中显示」「清除」。整条(除按钮外)可点击折叠/展开。
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .font(.caption.weight(.semibold))
                    Text("事件日志").font(.callout.weight(.medium))
                    Text("\(store.state.connectionLog.count)")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                revealLogInFinder()
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("在访达中打开磁盘上的连接日志文件(JSONL)")

            Button(role: .destructive) {
                store.dispatch(.clearConnectionLog)
            } label: {
                Label("清除", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(store.state.connectionLog.isEmpty)
            .help("清空连接日志(不影响已生效的规则 / 累计流量)")
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        Text("还没有事件——扩展被批准并有流量后,每条连接会实时出现在这里。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    /// 日志列表:LazyVStack 只渲染可见行,500 条环形缓冲下也不会全量构建。
    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(events) { entry in
                    EventLogRow(entry: entry, name: appName(entry), reason: eventReason(entry))
                    Divider().opacity(0.4)
                }
            }
        }
    }

    /// 优先级同连接表:目录扫描名 > 扩展解出的可读进程名 > 原始 processID。
    private func appName(_ entry: ConnectionLogEntry) -> String {
        store.state.catalog[entry.processID]?.displayName ?? entry.processDisplayName ?? entry.processID.value
    }

    /// 为一行事件推导「为什么这么走」的原因文案。**按当前 `store.state` 的规则重新推导**,是一个
    /// 近似:扩展在记录这条连接的那一刻做出的真实决策,若之后规则表 / 排除集被改过,可能与这里
    /// 显示的不同(拿不到当时快照,只能用当前规则反推)。都推不出时返回 nil(不臆测)。
    ///
    /// 推导顺序刻意与扩展 `effectiveRule` 的真实优先级一致(见 `EngineKit.ProcessOriginExclusion`
    /// 的接线注释:回环/上游排除 → 来源进程排除 → 每进程规则表):先看两档来源排除,再看用户规则表,
    /// 最后回落默认直连。用户规则的匹配逻辑镜像 `EngineKit.RuleMatcher.firstMatchRule`(App target
    /// 不链接 EngineKit、且 B2 不变量禁止跨包依赖其匹配层,故按 Core 模型**镜像不复用**——语义须与
    /// 之一致,与 `Core.EffectiveAppRule` 镜像 `RuleMatcher.firstAppLevelMatch` 同理)。
    private func eventReason(_ entry: ConnectionLogEntry) -> String? {
        let identifier = entry.processID.value
        let path = store.state.catalog[entry.processID]?.executablePath

        // 1) 环自愈完全旁路(最保守,扩展里最先判)。
        if isExcludedOrigin(identifier: identifier, path: path, by: store.state.loopAutoExclusions) {
            return "自动 · 回环旁路"
        }
        // 2) 本地代理来源强制直连。
        if isExcludedOrigin(identifier: identifier, path: path, by: store.state.dynamicOriginExclusion) {
            return "自动 · 本地代理直连"
        }
        // 3) 用户规则表:进程 × 主机 × 端口首个命中的**启用**规则(停用的从不进 wire,故跳过)。
        if let rule = firstEnabledRuleMatch(store.state.rules, app: identifier, host: entry.host, port: entry.port) {
            let portText = rule.portRange.map(Self.portLabel) ?? "任意端口"
            return "命中规则 \(rule.appPattern) · \(rule.hostPattern) · \(portText)"
        }
        // 4) 规则表不命中、实际又走了直连 → 默认直连。
        if entry.rule == .direct {
            return "默认直连"
        }
        // 其余(如经每进程赋值走代理/观测但规则表无命中)无法从规则表可靠反推,不臆测。
        return nil
    }

    /// 来源进程是否落在某档排除集里:签名标识精确命中(集合建时已滤掉 `a.out` 这类歧义标识),
    /// 或可执行文件路径命中——任一即算(镜像扩展侧两路信号 `ProcessOriginExclusion.shouldBypass`)。
    private func isExcludedOrigin(identifier: String, path: String?, by discovery: OriginExclusionDiscovery) -> Bool {
        if discovery.identifiers.contains(identifier) { return true }
        if let path, discovery.executablePaths.contains(path) { return true }
        return false
    }

    /// 规则表从上到下,返回首个「进程 × 主机 × 端口」三维都命中的**启用**规则;都不命中返回 nil。
    /// `EngineKit.RuleMatcher.firstMatchRule` 的镜像(见 `eventReason` 注释:为什么镜像不复用)。
    private func firstEnabledRuleMatch(_ rules: [ProxyMatchRule], app: String, host: String, port: UInt16) -> ProxyMatchRule? {
        for rule in rules where rule.isEnabled
            && EventGlob.matches(pattern: rule.appPattern, text: app)
            && EventGlob.matches(pattern: rule.hostPattern, text: host)
            && (rule.portRange?.contains(port) ?? true) {
            return rule
        }
        return nil
    }

    /// 端口区间的紧凑文案:单端口显示数字,区间用连字符。
    private static func portLabel(_ range: ClosedRange<UInt16>) -> String {
        range.lowerBound == range.upperBound ? "\(range.lowerBound)" : "\(range.lowerBound)–\(range.upperBound)"
    }

    /// 在访达中定位磁盘日志文件。文件还没生成时(首次运行 / 已清除)回落到选中其所在目录。
    private func revealLogInFinder() {
        let fileURL = ConnectionLogFileStore.defaultFileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }
}

/// 事件日志的一行:时间 · 进程名 · → 主机:端口 · 走法胶囊 · 状态文案。紧凑单行,对齐 Console.app 的日志密度。
private struct EventLogRow: View {
    let entry: ConnectionLogEntry
    let name: String
    /// 「为什么这么走」的原因(命中规则 / 自动旁路 / 默认直连),由 `TrafficPane.eventReason` 按
    /// 当前规则近似推导;推不出时为 nil(不显示副行)。
    let reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(entry.openedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)

                Text(name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)

                Text("→ \(entry.host):\(entry.port)")
                    .font(.caption).monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                RouteChip(rule: entry.rule, kind: entry.proxyKind)

                status
                    .font(.caption)
                    .frame(width: 68, alignment: .leading)
            }

            if let reason {
                // 次要色小字副行,缩进对齐到进程名列(时间列宽 72 + 间距 8),做「这条为什么这么走」的注脚。
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 80)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// 状态文案(与连接表语义一致):观测 → 已放行;opened → 活动;closed → 已关闭;failed → 失败。
    @ViewBuilder private var status: some View {
        if entry.rule == .observe {
            Label("已放行", systemImage: "eye").foregroundStyle(.orange)
        } else {
            switch entry.phase {
            case .opened: Label("活动", systemImage: "circle.fill").foregroundStyle(.green)
            case .closed: Label("已关闭", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            case .failed: Label("失败", systemImage: "xmark.octagon").foregroundStyle(.red)
            }
        }
    }
}

/// 极简 glob(只支持 `*`——匹配任意长度任意字符含点,大小写不敏感)。经典贪心回溯,零依赖。
/// `EngineKit.Glob` / `Core` 内 `Glob` 的**镜像**(见 `TrafficPane.eventReason` 注释:App target
/// 不链接 EngineKit,故镜像不复用;语义须与它们一致)。仅供本文件的原因推导用。
private enum EventGlob {
    static func matches(pattern: String, text: String) -> Bool {
        let pattern = Array(pattern.lowercased())
        let text = Array(text.lowercased())

        var textIndex = 0
        var patternIndex = 0
        var starPatternIndex = -1
        var starTextMark = 0

        while textIndex < text.count {
            if patternIndex < pattern.count, pattern[patternIndex] == text[textIndex] {
                textIndex += 1
                patternIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starPatternIndex = patternIndex
                starTextMark = textIndex
                patternIndex += 1
            } else if starPatternIndex != -1 {
                patternIndex = starPatternIndex + 1
                starTextMark += 1
                textIndex = starTextMark
            } else {
                return false
            }
        }

        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }
}

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

    /// 日志列表:整块渲染成可选中复制的等宽富文本(`NSTextView` 支撑,对齐 Console.app 的手感)。
    /// 每条一行「时间 · 进程 · → 目标 · 走法 · 状态[ · 原因]」,走法/状态按语义上色。用户在选区中
    /// (可能要拷贝)时刷新会暂停,避免把文字从选区下抽走。
    private var logList: some View {
        SelectableLogTextView(text: attributedLog)
    }

    /// 把当前(时间倒序)事件拼成一整段带色富文本,一行一条,供 `SelectableLogTextView` 显示。
    private var attributedLog: NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let out = NSMutableAttributedString()
        for (index, entry) in events.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(logLine(entry, font: mono))
        }
        return out
    }

    /// 一条日志渲染成一行富文本:时间(次要色)· 进程 · → 主机:端口 · 走法(语义色)· 状态(语义色)
    /// [ · 原因(更淡)]。字段间两个空格分隔,整行等宽,便于对齐与拷贝。
    private func logLine(_ entry: ConnectionLogEntry, font: NSFont) -> NSAttributedString {
        let line = NSMutableAttributedString()
        func seg(_ text: String, _ color: NSColor) {
            line.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        seg(entry.openedAt.formatted(date: .omitted, time: .standard) + "  ", .secondaryLabelColor)
        seg(appName(entry) + "  ", .labelColor)
        seg("→ \(entry.host):\(entry.port)  ", .labelColor)
        seg(Self.routeLabelText(rule: entry.rule, kind: entry.proxyKind) + "  ", Self.routeColor(entry.rule))
        let (statusText, statusColor) = Self.statusPresentation(entry)
        seg(statusText, statusColor)
        if let reason = eventReasonText(entry) {
            seg("  · " + reason, .tertiaryLabelColor)
        }
        return line
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
    private func eventReasonText(_ entry: ConnectionLogEntry) -> String? {
        let identifier = entry.processID.value
        let path = store.state.catalog[entry.processID]?.executablePath

        // 1) 环自愈完全旁路(最保守,扩展里最先判)。
        if isExcludedOrigin(identifier: identifier, path: path, by: store.state.loopAutoExclusions) {
            return String(localized: "自动 · 回环旁路")
        }
        // 2) 本地代理来源强制直连。
        if isExcludedOrigin(identifier: identifier, path: path, by: store.state.dynamicOriginExclusion) {
            return String(localized: "自动 · 本地代理直连")
        }
        // 3) 用户规则表:进程 × 主机 × 端口首个命中的**启用**规则(停用的从不进 wire,故跳过)。
        // 静态部分(「命中规则」/「任意端口」)走 String Catalog;模式串是动态数据,以插值 %@ 传入。
        if let rule = firstEnabledRuleMatch(store.state.rules, app: identifier, host: entry.host, port: entry.port) {
            if let range = rule.portRange {
                let portText = Self.portLabel(range)
                return String(localized: "命中规则 \(rule.appPattern) · \(rule.hostPattern) · \(portText)")
            } else {
                return String(localized: "命中规则 \(rule.appPattern) · \(rule.hostPattern) · 任意端口")
            }
        }
        // 4) 规则表不命中、实际又走了直连 → 默认直连。
        if entry.rule == .direct {
            return String(localized: "默认直连")
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

    /// 走法文案的 String 版(镜像 `RouteText.label`,那个返回 `LocalizedStringKey` 不能进富文本)。
    private static func routeLabelText(rule: ProxyRule, kind: ProxyKind?) -> String {
        switch (rule, kind) {
        case (.direct, _): String(localized: "直连")
        case (.block, _): String(localized: "拦截")
        case (.observe, _): String(localized: "观测")
        case (.proxied, .some(.socks5)): String(localized: "代理 · SOCKS5")
        case (.proxied, .some(.httpConnect)): String(localized: "代理 · HTTP")
        case (.proxied, .none): String(localized: "代理（回落直连）")
        }
    }

    /// 走法语义色的 `NSColor` 版(镜像 `RouteText.color` 的 SwiftUI `Color`,供 `NSAttributedString` 用)。
    private static func routeColor(_ rule: ProxyRule) -> NSColor {
        switch rule {
        case .direct: .systemGreen
        case .proxied: .controlAccentColor
        case .block: .systemRed
        case .observe: .systemOrange
        }
    }

    /// 状态文案 + 语义色(与连接表 / Inspector 同口径):观测→已放行;opened→活跃;closed→已关闭;failed→失败。
    private static func statusPresentation(_ entry: ConnectionLogEntry) -> (String, NSColor) {
        if entry.rule == .observe { return (String(localized: "已放行"), .systemOrange) }
        switch entry.phase {
        case .opened: return (String(localized: "活跃"), .systemGreen)
        case .closed: return (String(localized: "已关闭"), .secondaryLabelColor)
        case .failed: return (String(localized: "失败"), .systemRed)
        }
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

/// 可选中复制的日志文本视图:只读 `NSTextView`,整段富文本一行一条,支持跨行选中、⌘C 拷出纯文本
/// (对齐 Console.app)。走 AppKit 是因为 SwiftUI 的 `Text` 拷贝体验散、拿不到"整段可选"。
/// 刷新策略:用户正在选区中(可能要拷贝)时**跳过更新**,不把文字从选区下抽走;内容没变也不动。
private struct SelectableLogTextView: NSViewRepresentable {
    let text: NSAttributedString

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(text)
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        // 别把文字从活动选区下抽走——用户可能正选着要拷贝,等选区收起下一帧再刷新。
        if textView.selectedRange().length > 0 { return }
        // 内容没变就不重排,避免每次 state 变更都抖动滚动条。
        if textView.textStorage?.isEqual(to: text) == true { return }
        let origin = scroll.contentView.bounds.origin
        textView.textStorage?.setAttributedString(text)
        // 尽量保住滚动位置(内容在顶部增删时不完美,但不至于每刷新都跳回顶)。
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    final class Coordinator {
        weak var textView: NSTextView?
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

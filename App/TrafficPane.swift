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
                    EventLogRow(entry: entry, name: appName(entry))
                    Divider().opacity(0.4)
                }
            }
        }
    }

    /// 优先级同连接表:目录扫描名 > 扩展解出的可读进程名 > 原始 processID。
    private func appName(_ entry: ConnectionLogEntry) -> String {
        store.state.catalog[entry.processID]?.displayName ?? entry.processDisplayName ?? entry.processID.value
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

    var body: some View {
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

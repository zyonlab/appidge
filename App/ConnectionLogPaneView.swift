import SwiftUI
import Core
import AppFeature

/// 「连接」:每条 TCP 连接一行(对齐 Proxifier 的 Connections 视图)——进程 / 目标 host:port /
/// 命中动作 / 所用代理 / 状态 / 字节。数据来自扩展经 IPC 回灌的 `store.state.connectionLog`,
/// 最新的排在最前。UI 只读 state。
struct ConnectionLogPaneView: View {
    var store: Store

    /// 最新在前(reducer 里是追加,所以这里反转)。
    private var entries: [ConnectionLogEntry] {
        store.state.connectionLog.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("连接(共 \(store.state.connectionLog.count) 条,最新在前)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if entries.isEmpty {
                Text("还没有连接。扩展被批准并有流量后,这里会实时出现每条连接。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    ConnectionRow(entry: entry, appName: appName(for: entry.processID))
                }
            }
        }
        .padding()
    }

    private func appName(for id: ProcessID) -> String {
        store.state.catalog[id]?.displayName ?? id.value
    }
}

private struct ConnectionRow: View {
    let entry: ConnectionLogEntry
    let appName: String

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(appName).font(.callout)
                Text("\(entry.host):\(entry.port)")
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(routeLabel)
                    .font(.caption)
                    .foregroundStyle(entry.rule == .proxied ? Color.accentColor : Color.secondary)
                Text("↑\(entry.bytesUp)B ↓\(entry.bytesDown)B")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var routeLabel: String {
        switch (entry.rule, entry.proxyKind) {
        case (.direct, _): "直连"
        case (.proxied, .some(.socks5)): "代理 · SOCKS5"
        case (.proxied, .some(.httpConnect)): "代理 · HTTP"
        case (.proxied, .none): "代理(未配上游,回落直连)"
        }
    }

    private var statusDot: some View {
        Image(systemName: iconName)
            .foregroundStyle(iconColor)
            .font(.caption)
    }

    private var iconName: String {
        switch entry.phase {
        case .opened: "circle.fill"
        case .closed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch entry.phase {
        case .opened: .green
        case .closed: .secondary
        case .failed: .red
        }
    }
}

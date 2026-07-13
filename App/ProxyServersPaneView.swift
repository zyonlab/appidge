import SwiftUI
import Core
import AppFeature

/// 「代理服务器」配置面板：概念上对标 Proxifier 的「Proxy Servers」对话框——一个能
/// 增/删的上游代理列表，外加挑出当前「使用中」的那台。
///
/// 跟其它面板一样，UI 只做两件事：读 `store.state`、`dispatch(Action)`。视图里的
/// `@State` 只用于「添加」表单的输入草稿（本地 UI 状态），从不直接改 app state。
/// 故意做得朴素（用户明确说这轮 UI 先简单、以后精修），只用系统默认控件。
///
/// 编辑既有代理走「删除 + 重新添加」这一简化路径（本轮不做原地编辑表单）。
struct ProxyServersPaneView: View {
    var store: Store

    private var sortedServers: [ProxyServer] {
        store.state.proxyServers.values.sorted { $0.id.value < $1.id.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("代理服务器")
                .font(.headline)

            serverList

            Divider()

            AddProxyServerForm(store: store)
        }
        .padding()
    }

    @ViewBuilder
    private var serverList: some View {
        if sortedServers.isEmpty {
            Text("还没有配置代理服务器，用下面的表单添加一台。")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            List(sortedServers, id: \.id) { server in
                ProxyServerRow(
                    server: server,
                    isActive: store.state.activeProxyServerID == server.id,
                    onActivate: { store.dispatch(.setActiveProxyServer(server.id)) },
                    onRemove: { store.dispatch(.removeProxyServer(server.id)) }
                )
            }
        }
    }
}

/// 单台代理的一行：地址:端口 + 可选用户名，左侧标出是否「使用中」，右侧给切换/删除。
private struct ProxyServerRow: View {
    let server: ProxyServer
    let isActive: Bool
    let onActivate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(server.host):\(server.port)")
                    .monospacedDigit()
                if let username = server.username, !username.isEmpty {
                    Text(username)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isActive {
                Text("使用中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("设为使用中", action: onActivate)
            }

            Button("删除", role: .destructive, action: onRemove)
        }
    }
}

/// 「添加代理服务器」表单。`@State` 是本地输入草稿，不是 app state；点「添加」时组装一台
/// `ProxyServer`（id 用 UUID 保证唯一，允许同一 host:port 存多台）并 dispatch。
private struct AddProxyServerForm: View {
    var store: Store

    @State private var host = ""
    @State private var portText = ""
    @State private var username = ""
    @State private var password = ""

    private var parsedPort: UInt16? {
        UInt16(portText.trimmingCharacters(in: .whitespaces))
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespaces)
    }

    private var canAdd: Bool {
        !trimmedHost.isEmpty && parsedPort != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("添加代理服务器（SOCKS5）")
                .font(.subheadline)

            TextField("地址，如 127.0.0.1", text: $host)
            TextField("端口，如 1080", text: $portText)
            TextField("用户名（可选）", text: $username)
            SecureField("密码（可选）", text: $password)

            Button("添加", action: add)
                .disabled(!canAdd)
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func add() {
        guard let port = parsedPort else { return }
        let server = ProxyServer(
            id: ProxyServerID(UUID().uuidString),
            host: trimmedHost,
            port: port,
            kind: .socks5,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password
        )
        store.dispatch(.addProxyServer(server))
        host = ""
        portText = ""
        username = ""
        password = ""
    }
}

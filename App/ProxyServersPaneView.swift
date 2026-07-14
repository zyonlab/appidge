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

            RoutingModeSection(store: store, servers: sortedServers)

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

/// 「路由模式」区：对标 Proxifier 的 Proxy Chains + 冗余/均衡策略。选一种模式；非 single
/// 时勾选参与的上游（勾选顺序即链的跳序 / 故障转移的尝试序，显示为编号）。
///
/// UI 只读 `store.state.proxyRoutingMode`、只 `dispatch(.setProxyRoutingMode(...))`；模式↔种类
/// 的拍平与顺序保留逻辑都在 AppFeature 的 `RoutingModeKind` / `togglingMember`（已单测），
/// 视图不含业务判断。故意做得朴素（这轮 UI 先简单），排序沿用 id 升序。
private struct RoutingModeSection: View {
    var store: Store
    let servers: [ProxyServer]

    private var mode: ProxyRoutingMode { store.state.proxyRoutingMode }
    private var kind: RoutingModeKind { RoutingModeKind(mode) }
    private var selectedIDs: [ProxyServerID] { mode.orderedServerIDs }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("路由模式")
                .font(.subheadline)

            Picker("路由模式", selection: kindBinding) {
                Text("单台").tag(RoutingModeKind.single)
                Text("代理链").tag(RoutingModeKind.chain)
                Text("故障转移").tag(RoutingModeKind.failover)
                Text("负载均衡").tag(RoutingModeKind.loadBalance)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(Self.explanation(kind))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if kind != .single {
                memberPicker
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    @ViewBuilder
    private var memberPicker: some View {
        if servers.isEmpty {
            Text("先添加代理服务器，再选择参与的上游。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(servers, id: \.id) { server in
                    let position = selectedIDs.firstIndex(of: server.id).map { $0 + 1 }
                    Toggle(isOn: memberBinding(server.id)) {
                        HStack(spacing: 6) {
                            if let position {
                                Text("\(position).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Text("\(server.host):\(server.port)")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var kindBinding: Binding<RoutingModeKind> {
        Binding(
            get: { kind },
            // 切种类时把已选 id 顺序带过去，不因 single↔chain↔… 丢选择。
            set: { store.dispatch(.setProxyRoutingMode($0.mode(carrying: selectedIDs))) }
        )
    }

    private func memberBinding(_ id: ProxyServerID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { store.dispatch(.setProxyRoutingMode(mode.togglingMember(id, included: $0))) }
        )
    }

    private static func explanation(_ kind: RoutingModeKind) -> String {
        switch kind {
        case .single:
            "所有走代理的连接都用「使用中」的那台上游。"
        case .chain:
            "连接依次穿过选中的多台上游（client → 上游1 → 上游2 → … → 目标），顺序即下面的编号。"
        case .failover:
            "按编号顺序尝试，第一台连不上就换下一台，直到某台成功。"
        case .loadBalance:
            "每条新连接在选中的上游之间轮流，分摊流量。"
        }
    }
}

/// 单台代理的一行：地址:端口 + 可选用户名，左侧标出是否「使用中」，右侧给探活/切换/删除。
private struct ProxyServerRow: View {
    let server: ProxyServer
    let isActive: Bool
    let onActivate: () -> Void
    let onRemove: () -> Void

    // 「测试」这颗按钮的探活状态,view-local 瞬时态(idle/checking/reachable/unreachable)。
    // 真实探测走 App 的 NWConnectionProxyProbe，映射逻辑在已测的 ProxyChecker。
    @State private var checkStatus: ProxyCheckStatus = .idle

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(server.host):\(server.port)")
                        .monospacedDigit()
                    Text(Self.kindLabel(server.kind))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let username = server.username, !username.isEmpty {
                    Text(username)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            reachabilityIndicator
            Button("测试", action: runCheck)

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

    @ViewBuilder
    private var reachabilityIndicator: some View {
        switch checkStatus {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .reachable:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .help("可达")
        case .unreachable:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                .help("连不上（超时或被拒）")
        }
    }

    private func runCheck() {
        checkStatus = .checking
        let host = server.host
        let port = server.port
        Task {
            let status = await ProxyChecker.check(host: host, port: port, using: NWConnectionProxyProbe())
            await MainActor.run { checkStatus = status }
        }
    }

    private static func kindLabel(_ kind: ProxyKind) -> String {
        switch kind {
        case .socks5: "SOCKS5"
        case .httpConnect: "HTTP"
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
    @State private var kind: ProxyKind = .socks5

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
            Text("添加代理服务器")
                .font(.subheadline)

            Picker("协议", selection: $kind) {
                Text("SOCKS5").tag(ProxyKind.socks5)
                Text("HTTP CONNECT").tag(ProxyKind.httpConnect)
            }
            .pickerStyle(.segmented)

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
            kind: kind,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password
        )
        store.dispatch(.addProxyServer(server))
        host = ""
        portText = ""
        username = ""
        password = ""
        kind = .socks5
    }
}

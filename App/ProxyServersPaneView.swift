import SwiftUI
import Core
import AppFeature

/// 「代理服务器」配置(对标 Proxifier 的 Proxy Servers 对话框)。原生 `Table` + 底部工具栏
/// (＋添加 / −删除 / 设为使用中 / 测试)+ 路由模式区。选中一行,工具栏与右键菜单对它操作。
/// UI 只读 `store.state`、只 `dispatch(Action)`;探活状态(`checks`)是 view-local 瞬时态。
struct ProxyServersPaneView: View {
    var store: Store

    @State private var selection: ProxyServer.ID?
    @State private var checks: [ProxyServerID: ProxyCheckStatus] = [:]
    @State private var showingAdd = false

    private var sortedServers: [ProxyServer] {
        store.state.proxyServers.values.sorted { $0.id.value < $1.id.value }
    }

    var body: some View {
        VStack(spacing: 0) {
            if sortedServers.isEmpty {
                ContentUnavailableView(
                    "还没有代理服务器",
                    systemImage: "server.rack",
                    description: Text("点下面的「＋」添加一台上游代理。")
                )
                .frame(maxHeight: .infinity)
            } else {
                serverTable
            }
            Divider()
            toolbar
            Divider()
            RoutingModeSection(store: store, servers: sortedServers)
                .padding()
        }
        .sheet(isPresented: $showingAdd) {
            AddProxyServerSheet(store: store)
        }
    }

    private var serverTable: some View {
        Table(sortedServers, selection: $selection) {
            TableColumn("") { s in
                Image(systemName: store.state.activeProxyServerID == s.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(store.state.activeProxyServerID == s.id ? Color.accentColor : Color.secondary)
            }
            .width(26)

            TableColumn("地址:端口") { s in Text("\(s.host):\(s.port)").monospaced() }
            TableColumn("协议") { s in Text(Self.kindLabel(s.kind)) }.width(80)
            TableColumn("用户名") { s in
                Text((s.username?.isEmpty == false) ? s.username! : "—").foregroundStyle(.secondary)
            }
            TableColumn("探活") { s in checkCell(checks[s.id] ?? .idle) }.width(56)
        }
        .contextMenu(forSelectionType: ProxyServer.ID.self) { ids in
            if let id = ids.first {
                Button("设为使用中") { store.dispatch(.setActiveProxyServer(id)) }
                Button("测试") { runCheck(id) }
                Divider()
                Button("删除", role: .destructive) { store.dispatch(.removeProxyServer(id)) }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { showingAdd = true } label: { Image(systemName: "plus") }
                .help("添加代理服务器")
            Button { removeSelected() } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                .help("删除选中")
            Divider().frame(height: 14)
            Button("设为使用中") { if let id = selection { store.dispatch(.setActiveProxyServer(id)) } }
                .disabled(selection == nil)
            Button("测试") { if let id = selection { runCheck(id) } }
                .disabled(selection == nil)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func checkCell(_ status: ProxyCheckStatus) -> some View {
        switch status {
        case .idle: Text("—").foregroundStyle(.tertiary)
        case .checking: ProgressView().controlSize(.small)
        case .reachable: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("可达")
        case .unreachable: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("连不上（超时或被拒）")
        }
    }

    private func removeSelected() {
        guard let id = selection else { return }
        store.dispatch(.removeProxyServer(id))
        selection = nil
    }

    private func runCheck(_ id: ProxyServerID) {
        guard let server = store.state.proxyServers[id] else { return }
        checks[id] = .checking
        let host = server.host
        let port = server.port
        Task {
            let status = await ProxyChecker.check(host: host, port: port, using: NWConnectionProxyProbe())
            await MainActor.run { checks[id] = status }
        }
    }

    private static func kindLabel(_ kind: ProxyKind) -> String {
        switch kind {
        case .socks5: "SOCKS5"
        case .httpConnect: "HTTP"
        }
    }
}

/// 「路由模式」区：对标 Proxifier 的 Proxy Chains + 冗余/均衡策略。选一种模式；非 single
/// 时勾选参与的上游（勾选顺序即链的跳序 / 故障转移的尝试序，显示为编号）。模式↔种类的拍平与
/// 顺序保留逻辑在 AppFeature 的 `RoutingModeKind` / `togglingMember`（已单测）。
private struct RoutingModeSection: View {
    var store: Store
    let servers: [ProxyServer]

    private var mode: ProxyRoutingMode { store.state.proxyRoutingMode }
    private var kind: RoutingModeKind { RoutingModeKind(mode) }
    private var selectedIDs: [ProxyServerID] { mode.orderedServerIDs }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("路由模式").font(.subheadline)

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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var memberPicker: some View {
        if servers.isEmpty {
            Text("先添加代理服务器，再选择参与的上游。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(servers) { server in
                    let position = selectedIDs.firstIndex(of: server.id).map { $0 + 1 }
                    Toggle(isOn: memberBinding(server.id)) {
                        HStack(spacing: 6) {
                            if let position {
                                Text("\(position).").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Text("\(server.host):\(server.port)").font(.caption).monospacedDigit()
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
        case .single: "所有走代理的连接都用「使用中」的那台上游。"
        case .chain: "连接依次穿过选中的多台上游（client → 上游1 → 上游2 → … → 目标），顺序即下面的编号。"
        case .failover: "按编号顺序尝试，第一台连不上就换下一台，直到某台成功。"
        case .loadBalance: "每条新连接在选中的上游之间轮流，分摊流量。"
        }
    }
}

/// 「添加代理服务器」sheet(协议 / 地址 / 端口 / 认证)。添加成功后自动关闭。
private struct AddProxyServerSheet: View {
    var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var portText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var kind: ProxyKind = .socks5

    private var parsedPort: UInt16? { UInt16(portText.trimmingCharacters(in: .whitespaces)) }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    private var canAdd: Bool { !trimmedHost.isEmpty && parsedPort != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("添加代理服务器").font(.headline)
                Spacer()
                Button("取消") { dismiss() }
            }
            .padding()
            Divider()
            Form {
                Picker("协议", selection: $kind) {
                    Text("SOCKS5").tag(ProxyKind.socks5)
                    Text("HTTP CONNECT").tag(ProxyKind.httpConnect)
                }
                .pickerStyle(.segmented)
                TextField("地址", text: $host, prompt: Text("127.0.0.1"))
                TextField("端口", text: $portText, prompt: Text("1080"))
                TextField("用户名（可选）", text: $username)
                SecureField("密码（可选）", text: $password)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("添加", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding()
        }
        .frame(width: 380)
    }

    private func add() {
        guard let port = parsedPort else { return }
        store.dispatch(.addProxyServer(ProxyServer(
            id: ProxyServerID(UUID().uuidString),
            host: trimmedHost, port: port, kind: kind,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password
        )))
        dismiss()
    }
}

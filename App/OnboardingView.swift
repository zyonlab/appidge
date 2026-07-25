import SwiftUI
import Core
import AppFeature

/// 首次启动引导——**分步向导**:欢迎 → 启用网络扩展(带实时批准状态 + 直达系统设置)→ 设代理 →
/// 设规则 → 完成。重点是第 2 步:Developer ID 分发的系统扩展,macOS 强制用户首次去「系统设置」
/// 点允许(无法绕过,除非 MDM),这一步把用户直接带过去并实时反馈状态。
/// 跟其它面板一样,UI 只读 store.state、只 dispatch(Action)。
struct OnboardingView: View {
    var store: Store

    @State private var step: Step = .welcome

    enum Step: Int, CaseIterable {
        case welcome, extensionSetup, proxy, rules, done
    }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 20)
            Divider().padding(.top, 16)

            ScrollView {
                content
                    .padding(.horizontal, 40)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            }

            Divider()
            navBar
                .padding(16)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    // MARK: - 步骤进度点

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: s == step ? 22 : 7, height: 7)
                    .animation(.snappy, value: step)
            }
        }
    }

    // MARK: - 各步内容

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .extensionSetup: extensionStep
        case .proxy: ProxyStep(store: store)
        case .rules: rulesStep
        case .done: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            BrandIcon(size: 96)
            Text("appidge · 按进程代理").font(.title2).bold()
            Text("为每个应用单独指定走代理或直连,还能让不同应用走不同代理。代理异常时自动回退直连。")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 400)
            Text("下面几步带你启用扩展、配好代理与规则,大概一分钟。")
                .font(.callout).foregroundStyle(.tertiary)
        }
    }

    private var extensionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("启用网络扩展", "appidge 靠一个系统网络扩展接管流量。macOS 要求你**首次批准一次**——这是苹果的安全机制,任何同类工具都免不了。批准后永久生效,不用每次开都点。")

            let a = Self.activation(store.state.extensionActivation)
            HStack(spacing: 8) {
                Image(systemName: a.symbol).foregroundStyle(a.color)
                Text(a.label).foregroundStyle(a.color).font(.callout.weight(.medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                Button("启用扩展") { SystemExtensionActivator.shared.activate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.state.isLicenseActive)
                Button("打开系统设置") { SystemSettingsOpener.openExtensionsPane() }
            }

            Text("点「启用扩展」后,在弹出的系统提示或「系统设置 → 隐私与安全性 / 登录项与扩展 → 网络扩展」里允许 appidge。状态会在上面实时更新;显示「已启用」即可继续(没批准也能先往下走,回头再允许)。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rulesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("设置规则", "默认规则已经是「任意应用 → 走代理」,装好就能用。想更精细再调:")
            bulletRow("让某些应用直连", "在「应用」或「规则」页把它设为「直连」(比如公司内网、下载工具)。")
            bulletRow("不同应用走不同代理", "规则动作选「代理」时可指定走哪台上游——进程 X 走代理 A、进程 Y 走代理 B。")
            bulletRow("按主机/端口细分", "「规则」页可加「进程 × 主机 × 端口 → 动作」的细粒度规则,从上到下首个命中生效。")
            Text("这些都能在主界面随时改,现在跳过也没关系。")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            BrandIcon(size: 88)
            Text("准备就绪").font(.title2).bold()
            Text("扩展批准并有流量后,「活动」页会实时列出每条连接。状态栏显示「引擎正常」即在接管。")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
    }

    // MARK: - 导航

    private var navBar: some View {
        HStack {
            if step != .welcome {
                Button("上一步") { back() }
            }
            Spacer()
            if step == .done {
                Button("开始使用") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(step == .rules ? "下一步" : "继续") { next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func next() {
        withAnimation(.snappy) {
            if let n = Step(rawValue: step.rawValue + 1) { step = n }
        }
    }

    private func back() {
        withAnimation(.snappy) {
            if let p = Step(rawValue: step.rawValue - 1) { step = p }
        }
    }

    private func finish() {
        guard store.state.isLicenseActive else { return }
        SystemExtensionActivator.shared.activate()   // 幂等:引导里没点启用也兜底激活一次
        store.dispatch(.onboardingCompleted)
        Task { await FilePersistenceStore().save(PersistedConfiguration(from: store.state)) }
    }

    // MARK: - 小件

    private func stepHeader(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3).bold()
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bulletRow(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 扩展激活状态 → 引导里的符号 + 语义色 + 文案。绿=已启用,橙=待批准/安装中,红=失败,灰=未接入。
    private static func activation(_ state: ExtensionActivation) -> ActivationStyle {
        switch state {
        case .active: ActivationStyle("checkmark.shield.fill", "已启用,可以继续", .green)
        case .activePendingReboot: ActivationStyle("arrow.clockwise.circle.fill", "已启用（新版本待重启生效）", .orange)
        case .inactive: ActivationStyle("bolt.horizontal.circle", "未接入——点「启用扩展」", .secondary)
        case .activating: ActivationStyle("arrow.triangle.2.circlepath", "安装中…", .orange)
        case .needsApproval: ActivationStyle("exclamationmark.circle.fill", "待批准——去系统设置点「允许」", .orange)
        case .disabled: ActivationStyle("bolt.slash.circle", "已停用——去系统设置重新开启", .orange)
        case .failed(let reason): ActivationStyle("xmark.octagon.fill", "安装失败:\(reason)", .red)
        }
    }
}

/// 引导里一行激活状态的展示样式（符号 + 文案 + 语义色）。取代三元组，满足 large_tuple。
private struct ActivationStyle {
    let symbol: String
    let label: LocalizedStringKey
    let color: Color
    init(_ symbol: String, _ label: LocalizedStringKey, _ color: Color) {
        self.symbol = symbol
        self.label = label
        self.color = color
    }
}

/// 「设代理」步骤:内嵌精简加代理表单(与 ProxyServersPaneView 的 AddProxyServerSheet 同口径),
/// 多次可加,列出已添加的;可留空跳过(之后在「代理」页补)。拆成独立 View 以便持有自己的输入 @State。
private struct ProxyStep: View {
    var store: Store

    @State private var host = ""
    @State private var portText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var kind: ProxyKind = .socks5

    private var parsedPort: UInt16? { UInt16(portText.trimmingCharacters(in: .whitespaces)) }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    private var canAdd: Bool { !trimmedHost.isEmpty && parsedPort != nil }
    private var servers: [ProxyServer] {
        store.state.proxyServers.values.sorted { $0.host.localizedCompare($1.host) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("添加代理服务器").font(.title3).bold()
                Text("填一台你的上游代理(SOCKS5 / HTTP)。可以加多台,之后规则里能指定谁走哪台。没有也能跳过,以后在「代理」页补。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !servers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(servers) { s in
                        Label("\(s.host):\(s.port) · \(s.kind == .socks5 ? "SOCKS5" : "HTTP")",
                              systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

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
            .frame(height: 210)

            HStack {
                Spacer()
                Button("添加这台", action: add).disabled(!canAdd)
            }
        }
    }

    private func add() {
        guard let port = parsedPort else { return }
        store.dispatch(.addProxyServer(ProxyServer(
            id: ProxyServerID(UUID().uuidString),
            host: trimmedHost, port: port, kind: kind,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password
        )))
        // 加完清空输入,方便连着加下一台;已添加的会出现在上方列表。
        host = ""; portText = ""; username = ""; password = ""
    }
}

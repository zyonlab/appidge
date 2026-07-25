import SwiftUI
import Core
import AppFeature

/// 直达「系统设置 → 通用 → 登录项与扩展」——系统扩展批准/重新启用都在这个面板。
/// 对齐 Proxifier 的引导顺滑度:告诉用户去哪不如直接带过去。
enum SystemSettingsOpener {
    static func openExtensionsPane() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 全局设置(苹果原生 `Settings` 场景,⌘, 打开)。分组 `Form`:代理总开关 / UDP 策略 / 抓包 /
/// 内置规则说明。这些是「全局、少改」的项,从主窗口移到这里,让主窗口专注连接监视。
struct SettingsView: View {
    var store: Store
    /// 界面语言。首次默认与 `LanguageBootstrap` 同源跟随系统；改动写入 AppleLanguages 并重启。
    @AppStorage(AppLanguage.storageKey) private var appLanguage: AppLanguage = AppLanguage.defaultLanguage

    var body: some View {
        Form {
            Section("通用") {
                Picker("语言", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.labelKey).tag(language)
                    }
                }
                .onChange(of: appLanguage) { _, newValue in
                    // 写 AppleLanguages 并重启:重启后 Bundle.main 加载对应 .lproj,全 UI 一致切换。
                    LanguageBootstrap.switchTo(newValue)
                }
                Text("切换语言会重启 app 后生效。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("首次引导") {
                    Button("查看引导流程") { store.dispatch(.reopenOnboarding) }
                        .controlSize(.small)
                }
                Text("重新进入首次引导流程用于测试 / 评估;主窗口会切到引导页,走完即恢复。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LicenseSettingsView(store: store)

            Section("代理") {
                LabeledContent("系统扩展") {
                    HStack(spacing: 8) {
                        let a = Self.activation(store.state.extensionActivation)
                        Text(a.label).foregroundStyle(a.color)
                        if !store.state.extensionActivation.isRunning {
                            Button("启用") { SystemExtensionActivator.shared.activate() }
                                .controlSize(.small)
                                .disabled(!store.state.isLicenseActive)
                            Button("打开系统设置") { SystemSettingsOpener.openExtensionsPane() }
                                .controlSize(.small)
                        }
                    }
                }
                LabeledContent("引擎状态") {
                    Text(store.state.isEngineHealthy ? LocalizedStringKey("正常") : LocalizedStringKey("异常，已回退直连"))
                        .foregroundStyle(store.state.isEngineHealthy ? Color.secondary : Color.red)
                }
                if case .failed(let reason) = store.state.extensionActivation {
                    Text("扩展加载失败：\(reason)")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !store.state.extensionActivation.isRunning {
                    Text("流量只有在系统扩展被批准并运行后才会真正被接管——点「启用」，再去「系统设置 → 隐私与安全性」允许。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("网络接管") {
                if store.state.extensionNeedsRebind {
                    Label {
                        Text("接管会话绑在旧扩展实例上（运行 \(store.state.runningExtensionVersion ?? "?")、已安装 \(store.state.bundledExtensionVersion ?? "?")）——流量可能被交给僵尸扩展。已自动尝试重绑；若仍异常，点「重启接管」，或重启电脑清理旧扩展。")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
                LabeledContent("恢复出口") {
                    HStack(spacing: 8) {
                        Button("重启接管") {
                            TransparentProxyController.restart()
                        }
                        .disabled(!store.state.isLicenseActive)
                        Button("停止接管") {
                            TransparentProxyController.stop()
                        }
                        Button("重置（移除代理配置）", role: .destructive) {
                            TransparentProxyController.reset()
                        }
                    }
                    .controlSize(.small)
                }
                Text("网络出问题时的恢复出口，无需重启电脑：「重启接管」把会话重新绑定到最新扩展（等于在系统设置里关开一次网络扩展，修复「拦到流量却不转发」的僵尸态）；「停止接管」结束当前会话，所有应用立即恢复原生直连；「重置」进一步把系统网络设置里的 appidge 代理配置整个移除（系统扩展保持安装）。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("UDP / QUIC") {
                Picker("代理进程的 UDP", selection: Binding(
                    get: { store.state.udpPolicy },
                    set: { store.dispatch(.setUDPPolicy($0)) }
                )) {
                    Text("拦截止漏").tag(UDPPolicy.block)
                    Text("直连放行").tag(UDPPolicy.direct)
                    Text("SOCKS5 代理").tag(UDPPolicy.proxySOCKS5)
                }
                .disabled(!store.state.isLicenseActive)
                Text(Self.udpHint(store.state.udpPolicy))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("诊断与抓包") {
                Toggle("逐连接抓包（.dmp）", isOn: Binding(
                    get: { store.state.isPacketCaptureEnabled },
                    set: { store.dispatch(.setPacketCaptureEnabled($0)) }
                ))
                .disabled(!store.state.isLicenseActive)
                Text("开启后逐连接把原始字节写进 App Group 容器的 captures/*.dmp（占磁盘、涉隐私）。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("内置规则") {
                Label("本地 / 回环地址（127.0.0.1、::1、localhost）始终直连，不经代理（不可关闭）",
                      systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.secondary)
                // 对齐 Proxifier 检测到环后 auto-created 规则的「可见性」:自动旁路不是黑盒,
                // 在这里如实列出(端口发现 + 环检测自愈两个来源的并集)。
                let direct = store.state.dynamicOriginExclusion
                let bypass = store.state.loopAutoExclusions
                if !direct.identifiers.isEmpty || !direct.executablePaths.isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("识别到的本地代理进程（接管并强制直连，绝不代理回它自己）：")
                            Text((direct.identifiers.sorted() + direct.executablePaths.sorted())
                                .joined(separator: "  ·  "))
                                .monospaced().textSelection(.enabled)
                        }
                        .font(.callout)
                    } icon: { Image(systemName: "arrow.right.circle") }
                    .foregroundStyle(.secondary)
                }
                if !bypass.identifiers.isEmpty || !bypass.executablePaths.isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("环检测自愈加入的完全旁路（数据通路彻底不接管，本次运行内有效）：")
                            Text((bypass.identifiers.sorted() + bypass.executablePaths.sorted())
                                .joined(separator: "  ·  "))
                                .monospaced().textSelection(.enabled)
                        }
                        .font(.callout)
                    } icon: { Image(systemName: "arrow.uturn.right.circle") }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 440)
    }

    /// 扩展激活状态 → 设置页里的一行文案 + 颜色。待批准用橙色(需用户行动),失败/异常用红,其余次要灰。
    /// 文案是 LocalizedStringKey，随 `\.locale` 环境即时本地化。
    private static func activation(_ state: ExtensionActivation) -> (label: LocalizedStringKey, color: Color) {
        switch state {
        case .active: ("已接管", .secondary)
        case .inactive: ("未接入", .secondary)
        case .activating: ("安装中…", .orange)
        case .needsApproval: ("待批准（去系统设置允许）", .orange)
        case .disabled: ("已停用（系统设置 → 登录项与扩展 里开启）", .orange)
        case .failed: ("未安装", .red)
        }
    }

    private static func udpHint(_ policy: UDPPolicy) -> LocalizedStringKey {
        switch policy {
        case .block: "默认：代理进程的 UDP/QUIC 一律拦截，逼 QUIC 回落 TCP 走代理，不泄漏。"
        case .direct: "放行直连：UDP 可用，但绕过代理、可能暴露访问目标（游戏 / VoIP 需要 UDP 时用）。"
        case .proxySOCKS5: "上游是 SOCKS5 时经 UDP ASSOCIATE 真正代理；上游非 SOCKS5 则退回拦截。"
        }
    }
}

/// 「许可证」设置面板。**只读 State、只 dispatch Action**——网络与 Keychain 都在 Store 的
/// effect handler（注入协议）里，View 不碰。购买只打开官网/Hosted Checkout；v1 用户从 Polar 邮件
/// 复制 key 回来粘贴激活，无浏览器回跳自动灌 key。授权服务故障绝不阻塞其它设置或接管路径。
struct LicenseSettingsView: View {
    var store: Store
    @State private var keyInput: String = ""

    var body: some View {
        Section("许可证") {
            statusRow
            switch store.state.licensePhase {
            case .licensed, .validating, .gracePeriod, .deactivating:
                activeDetails
            case .trial, .trialExpired:
                trialDetails
            case .unlicensed, .activating, .revoked, .expired, .recoverableError:
                activationControls
            }
        }
    }

    /// 试用态（试用中/已到期）：一句说明 + 复用未激活时的凭证输入/购买控件。剩余天数在 `statusRow`
    /// 经 `display(_:)` 展示，这里不重复列。`.trial`/`.trialExpired` 是 Core 新增相位（待集成后编译）。
    @ViewBuilder
    private var trialDetails: some View {
        Text("试用期内可使用全部功能；购买许可证解除限制并支持后续更新。")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        activationControls
    }

    private var statusRow: some View {
        LabeledContent("状态") {
            HStack(spacing: 8) {
                let display = Self.display(store.state.licensePhase)
                Text(display.label).foregroundStyle(display.color)
                if store.state.licensePhase == .activating
                    || store.state.licensePhase == .validating
                    || store.state.licensePhase == .deactivating {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var activeDetails: some View {
        if let info = store.state.license {
            LabeledContent("激活数") {
                Text(Self.activationsText(used: info.activations, limit: info.activationLimit))
            }
            if let expiresAt = info.expiresAt {
                LabeledContent("到期") { Text(expiresAt, style: .date) }
            } else {
                LabeledContent("类型") { Text("买断（永久）") }
            }
        }
        HStack(spacing: 8) {
            Button("刷新校验") { store.dispatch(.licenseValidateRequested(now: Date())) }
            Button("本机停用", role: .destructive) { store.dispatch(.licenseDeactivateRequested) }
        }
        .controlSize(.small)
        .disabled(store.state.licensePhase == .validating || store.state.licensePhase == .deactivating)
        Text("「本机停用」释放一个激活名额，便于换机后在新机激活。授权信息保存在系统钥匙串。")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var activationControls: some View {
        errorHintView
        TextField("粘贴 license key", text: $keyInput)
            .textFieldStyle(.roundedBorder)
            .disabled(store.state.licensePhase == .activating)
        HStack(spacing: 8) {
            let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            Button("激活") { store.dispatch(.licenseActivateRequested(licenseKey: trimmed)) }
                .disabled(trimmed.count < 8 || store.state.licensePhase == .activating)
            if store.state.licensePhase == .expired, store.state.license != nil {
                Button("重新校验") { store.dispatch(.licenseValidateRequested(now: Date())) }
            }
            if !LicenseBuildConfig.checkoutURL.isEmpty {
                Button("购买许可证") { store.dispatch(.licensePurchaseRequested(checkoutURL: LicenseBuildConfig.checkoutURL)) }
            }
        }
        .controlSize(.small)
        Text("购买后从 Polar 的确认邮件或客户门户复制 license key，粘贴到上方激活。")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var errorHintView: some View {
        if case .recoverableError(let code) = store.state.licensePhase {
            Text(Self.errorHint(code)).font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if store.state.licensePhase == .revoked {
            Text("此许可证已被吊销（退款/拒付）。如有疑问请通过退款政策页的联系入口联系我们。")
                .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else if store.state.licensePhase == .expired {
            Text("此许可证已过期。续订后可重新激活。")
                .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func display(_ phase: LicensePhase) -> (label: LocalizedStringKey, color: Color) {
        switch phase {
        case .licensed: ("已授权", .green)
        case .validating: ("校验中…", .secondary)
        case .gracePeriod: ("离线宽限中（暂时联系不上授权服务，仍可使用）", .orange)
        case .deactivating: ("停用中…", .secondary)
        case .activating: ("激活中…", .secondary)
        case .unlicensed: ("未激活", .secondary)
        case .revoked: ("已吊销", .red)
        case .expired: ("已过期", .red)
        case .recoverableError: ("激活未完成", .orange)
        // Core 新增试用相位（待集成后编译）：试用中显示剩余天数，到期显示已结束。
        case .trial(let days): ("试用 · 剩 \(days) 天", .blue)
        case .trialExpired: ("试用已结束", .red)
        }
    }

    private static func activationsText(used: Int, limit: Int?) -> String {
        guard let limit else { return "\(used) / 无限" }
        return "\(used) / \(limit)"
    }

    private static func errorHint(_ code: String) -> LocalizedStringKey {
        switch code {
        case "activationLimit": "激活名额已用尽：请在其它设备「本机停用」后再试，或联系支持。"
        case "invalidLicense": "license key 无效：请核对是否从 Polar 邮件完整复制。"
        default: "暂时无法连接授权服务，请检查网络后重试。"
        }
    }
}

/// 未授权时的主窗口 capability gate。它只暴露激活、恢复校验、购买与设置入口；代理启动、
/// 规则编辑和其它付费界面完全不构建，避免仅靠按钮约定造成绕过。
struct LicenseGateView: View {
    var store: Store
    @State private var keyInput = ""
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 18) {
            BrandIcon(size: 88)
            Text("激活 Appidge").font(.title2).bold()
            Text(statusText)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            TextField("粘贴 license key", text: $keyInput)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .disabled(store.state.licensePhase == .activating)

            HStack(spacing: 10) {
                let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                Button("激活") {
                    store.dispatch(.licenseActivateRequested(licenseKey: trimmed))
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.count < 8 || store.state.licensePhase == .activating)

                if store.state.licensePhase == .expired, store.state.license != nil {
                    Button("重新校验") {
                        store.dispatch(.licenseValidateRequested(now: Date()))
                    }
                    .disabled(store.state.licensePhase == .validating)
                }

                if !LicenseBuildConfig.checkoutURL.isEmpty {
                    Button("购买许可证") {
                        store.dispatch(.licensePurchaseRequested(checkoutURL: LicenseBuildConfig.checkoutURL))
                    }
                }
            }

            if store.state.licensePhase == .activating || store.state.licensePhase == .validating {
                ProgressView().controlSize(.small)
            }

            Button("打开设置与恢复工具") { openSettings() }
                .buttonStyle(.link)
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 460)
    }

    private var statusText: LocalizedStringKey {
        switch store.state.licensePhase {
        case .unlicensed: "输入购买后获得的许可证密钥，激活后才能启动网络接管与编辑规则。"
        case .activating: "正在激活许可证…"
        case .revoked: "此许可证已被吊销。你可以输入新的许可证密钥，或联系支持。"
        case .expired: "许可证已过期或离线宽限已耗尽。联网后可重新校验，续订后会恢复。"
        case .recoverableError: "激活未完成，请检查密钥或网络后重试。"
        case .validating: "正在重新校验许可证…"
        case .licensed, .gracePeriod, .deactivating: "许可证已激活。"
        // Core 新增试用相位（待集成后编译）。`.trial` 期 isLicenseActive 为真、不会走到本门；
        // `.trialExpired` 期落到此门，提示试用结束并引导购买/输入凭证。
        case .trial: "试用中，可使用全部功能。"
        case .trialExpired: "试用期已结束。购买许可证后可继续使用全部功能，或粘贴已购买的许可证密钥。"
        }
    }

    private var statusColor: Color {
        switch store.state.licensePhase {
        case .revoked, .expired, .trialExpired: .red
        case .recoverableError: .orange
        default: .secondary
        }
    }
}

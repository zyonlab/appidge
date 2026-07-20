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
    /// 界面语言。默认英文;改动写入 AppleLanguages 并重启 app 生效(见 `LanguageBootstrap`)。
    @AppStorage(AppLanguage.storageKey) private var appLanguage: AppLanguage = .english

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

            Section("代理") {
                LabeledContent("系统扩展") {
                    HStack(spacing: 8) {
                        let a = Self.activation(store.state.extensionActivation)
                        Text(a.label).foregroundStyle(a.color)
                        if !store.state.extensionActivation.isRunning {
                            Button("启用") { SystemExtensionActivator.shared.activate() }
                                .controlSize(.small)
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
                            Task { await TransparentProxyController.restart() }
                        }
                        Button("停止接管") {
                            Task { await TransparentProxyController.stop() }
                        }
                        Button("重置（移除代理配置）", role: .destructive) {
                            Task { await TransparentProxyController.reset() }
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
                Text(Self.udpHint(store.state.udpPolicy))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("诊断与抓包") {
                Toggle("逐连接抓包（.dmp）", isOn: Binding(
                    get: { store.state.isPacketCaptureEnabled },
                    set: { store.dispatch(.setPacketCaptureEnabled($0)) }
                ))
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

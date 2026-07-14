import SwiftUI
import Core
import AppFeature

/// 全局设置(苹果原生 `Settings` 场景,⌘, 打开)。分组 `Form`:代理总开关 / UDP 策略 / 抓包 /
/// 内置规则说明。这些是「全局、少改」的项,从主窗口移到这里,让主窗口专注连接监视。
struct SettingsView: View {
    var store: Store

    var body: some View {
        Form {
            Section("代理") {
                Toggle("全局代理", isOn: Binding(
                    get: { store.state.isGlobalProxyEnabled },
                    set: { store.dispatch(.setGlobalProxyEnabled($0)) }
                ))
                LabeledContent("引擎状态") {
                    Text(store.state.isEngineHealthy ? "正常" : "异常，已回退直连")
                        .foregroundStyle(store.state.isEngineHealthy ? Color.secondary : Color.red)
                }
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
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 440)
    }

    private static func udpHint(_ policy: UDPPolicy) -> String {
        switch policy {
        case .block: "默认：代理进程的 UDP/QUIC 一律拦截，逼 QUIC 回落 TCP 走代理，不泄漏。"
        case .direct: "放行直连：UDP 可用，但绕过代理、可能暴露访问目标（游戏 / VoIP 需要 UDP 时用）。"
        case .proxySOCKS5: "上游是 SOCKS5 时经 UDP ASSOCIATE 真正代理；上游非 SOCKS5 则退回拦截。"
        }
    }
}

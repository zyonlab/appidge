import SwiftUI
import Core
import AppFeature

/// 三区窗口：目录 / 规则 / 活动监视器。UI 只做两件事：读 store.state、dispatch(Action)。
struct ContentView: View {
    var store: Store

    var body: some View {
        TabView {
            DirectoryPaneView(store: store)
                .tabItem { Label("目录", systemImage: "folder") }
            RulesPaneView(store: store)
                .tabItem { Label("规则", systemImage: "list.bullet") }
            RulesEditorPaneView(store: store)
                .tabItem { Label("规则表", systemImage: "list.number") }
            ProxyServersPaneView(store: store)
                .tabItem { Label("代理服务器", systemImage: "server.rack") }
            ActivityMonitorPaneView(store: store)
                .tabItem { Label("活动监视器", systemImage: "waveform.path.ecg") }
            ConnectionLogPaneView(store: store)
                .tabItem { Label("连接", systemImage: "point.3.filled.connected.trianglepath.dotted") }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

struct DirectoryPaneView: View {
    var store: Store

    var body: some View {
        Form {
            Toggle("全局代理", isOn: Binding(
                get: { store.state.isGlobalProxyEnabled },
                set: { store.dispatch(.setGlobalProxyEnabled($0)) }
            ))
            Text(store.state.isEngineHealthy ? "引擎正常" : "引擎异常，已回退直连")
                .foregroundStyle(store.state.isEngineHealthy ? Color.primary : Color.red)
        }
        .padding()
    }
}

struct RulesPaneView: View {
    var store: Store

    private var sortedProcesses: [MonitoredProcess] {
        store.state.processes.values.sorted { $0.id.value < $1.id.value }
    }

    var body: some View {
        List(sortedProcesses, id: \.id) { process in
            HStack {
                Text(process.displayName)
                Spacer()
                Picker("规则", selection: Binding(
                    get: { process.rule },
                    set: { store.dispatch(.assignRule(processID: process.id, rule: $0)) }
                )) {
                    Text("直连").tag(ProxyRule.direct)
                    Text("代理").tag(ProxyRule.proxied)
                }
                .labelsHidden()
                .frame(width: 120)
            }
        }
    }
}

struct ActivityMonitorPaneView: View {
    var store: Store

    private var sortedProcesses: [MonitoredProcess] {
        store.state.processes.values.sorted { $0.id.value < $1.id.value }
    }

    var body: some View {
        List(sortedProcesses, id: \.id) { process in
            HStack {
                Text(process.displayName)
                Spacer()
                Text("↑\(process.stats.bytesUp)B ↓\(process.stats.bytesDown)B")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Picker("规则", selection: Binding(
                    get: { process.rule },
                    set: { store.dispatch(.assignRule(processID: process.id, rule: $0)) }
                )) {
                    Text("直连").tag(ProxyRule.direct)
                    Text("代理").tag(ProxyRule.proxied)
                }
                .labelsHidden()
                .frame(width: 120)
                Button("诊断") {
                    store.dispatch(.requestDiagnostic(processID: process.id, kinds: Core.DiagnosticKind.allCases))
                }
            }
        }
    }
}

struct MenuBarView: View {
    var store: Store

    var body: some View {
        Toggle("全局代理", isOn: Binding(
            get: { store.state.isGlobalProxyEnabled },
            set: { store.dispatch(.setGlobalProxyEnabled($0)) }
        ))
        Divider()
        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }
}

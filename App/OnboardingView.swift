import SwiftUI
import Core
import AppFeature

/// 首次启动引导：只做两件事——简单说明 app 是干什么的，一个按钮触发系统扩展激活
/// 请求并把引导标成已完成。跟其它面板一样，UI 只读 store.state、只 dispatch(Action)。
///
/// 故意做得很简陋（用户明确说了这轮 UI 可以简单，以后再精修），不引入新的视觉系统，
/// 只用系统默认控件，跟 App/ContentView.swift 的朴素风格保持一致。
struct OnboardingView: View {
    var store: Store

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "network")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("appidge · 按进程代理")
                .font(.title2)
                .bold()

            Text("按你设定的规则，为每个应用单独决定直连还是走代理；引擎异常时自动回退直连，不影响你的正常上网。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("开始使用") {
                SystemExtensionActivator.shared.activate()
                store.dispatch(.onboardingCompleted)
                Task {
                    await FilePersistenceStore().save(PersistedConfiguration(from: store.state))
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}

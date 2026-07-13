import SwiftUI
import Core
import AppFeature

@main
struct AppidgeApp: App {
    @State private var store = Store()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .onAppear { SystemExtensionActivator.shared.activate() }
        }

        MenuBarExtra("appidge", systemImage: "network") {
            MenuBarView(store: store)
        }
    }
}

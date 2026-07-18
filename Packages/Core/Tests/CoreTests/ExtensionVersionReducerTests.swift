import Testing
@testable import Core

@Suite("Reducer — 扩展版本握手:检测会话绑在旧 provider 上")
struct ExtensionVersionReducerTests {

    @Test("两版本都未知时不误报需要重绑")
    func unknownDoesNotFlag() {
        #expect(AppState().extensionNeedsRebind == false)
        var s = AppState(runningExtensionVersion: "36")
        #expect(s.extensionNeedsRebind == false) // 缺包内版本
        s = AppState(bundledExtensionVersion: "36")
        #expect(s.extensionNeedsRebind == false) // 缺运行版本
    }

    @Test("运行版本 == 包内版本 → 不需要重绑")
    func matchNoRebind() {
        let s = AppState(runningExtensionVersion: "36", bundledExtensionVersion: "36")
        #expect(s.extensionNeedsRebind == false)
    }

    @Test("运行版本 != 包内版本 → 需要重绑(会话绑在旧 provider 上)")
    func mismatchNeedsRebind() {
        let s = AppState(runningExtensionVersion: "34", bundledExtensionVersion: "36")
        #expect(s.extensionNeedsRebind == true)
    }

    @Test("extensionVersionReported 写入运行版本,未变化不产生多余变更")
    func reportsRunningVersion() {
        let (s1, e1) = Reducer.reduce(AppState(), .extensionVersionReported("34"))
        #expect(s1.runningExtensionVersion == "34")
        #expect(e1.isEmpty)
        let (s2, _) = Reducer.reduce(s1, .extensionVersionReported("34"))
        #expect(s2 == s1) // 幂等
    }

    @Test("bundledExtensionVersionSet 写入包内版本")
    func setsBundledVersion() {
        let (s, e) = Reducer.reduce(AppState(), .bundledExtensionVersionSet("36"))
        #expect(s.bundledExtensionVersion == "36")
        #expect(e.isEmpty)
    }

    @Test("回报旧运行版本 + 包内新版本 → extensionNeedsRebind 变真")
    func handshakeDetectsStaleBinding() {
        var (s, _) = Reducer.reduce(AppState(), .bundledExtensionVersionSet("36"))
        (s, _) = Reducer.reduce(s, .extensionVersionReported("34"))
        #expect(s.extensionNeedsRebind == true)
        // 升级重绑后新扩展回报 36 → 不再需要重绑。
        (s, _) = Reducer.reduce(s, .extensionVersionReported("36"))
        #expect(s.extensionNeedsRebind == false)
    }
}

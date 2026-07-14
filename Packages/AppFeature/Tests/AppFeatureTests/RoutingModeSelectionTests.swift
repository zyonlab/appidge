import Testing
import Core
@testable import AppFeature

/// 路由模式面板的纯选择逻辑：把带关联值的 `Core.ProxyRoutingMode` 拍平成 Picker 用的
/// `RoutingModeKind`，并在切换种类 / 勾选成员时**保留已选上游的顺序**。这些是 View 绑定
/// 背后的真逻辑（切 single↔chain 不丢选择、勾选按点击顺序进链），值得单测钉住。
@Suite("RoutingModeKind + ProxyRoutingMode selection helpers")
struct RoutingModeSelectionTests {

    private let a = Core.ProxyServerID("a")
    private let b = Core.ProxyServerID("b")
    private let c = Core.ProxyServerID("c")

    @Test("every ProxyRoutingMode flattens to its matching kind")
    func kindFromMode() {
        #expect(RoutingModeKind(.single) == .single)
        #expect(RoutingModeKind(.chain([a])) == .chain)
        #expect(RoutingModeKind(.failover([a])) == .failover)
        #expect(RoutingModeKind(.loadBalance([a])) == .loadBalance)
    }

    @Test("mode(carrying:) rebuilds the associated mode; single ignores the id list")
    func modeCarrying() {
        #expect(RoutingModeKind.single.mode(carrying: [a, b]) == .single)
        #expect(RoutingModeKind.chain.mode(carrying: [a, b]) == .chain([a, b]))
        #expect(RoutingModeKind.failover.mode(carrying: [a]) == .failover([a]))
        #expect(RoutingModeKind.loadBalance.mode(carrying: [b, a]) == .loadBalance([b, a]))
    }

    @Test("orderedServerIDs exposes the carried list (empty for single)")
    func orderedServerIDs() {
        #expect(Core.ProxyRoutingMode.single.orderedServerIDs == [])
        #expect(Core.ProxyRoutingMode.chain([a, b]).orderedServerIDs == [a, b])
        #expect(Core.ProxyRoutingMode.failover([c]).orderedServerIDs == [c])
        #expect(Core.ProxyRoutingMode.loadBalance([b, a]).orderedServerIDs == [b, a])
    }

    @Test("switching kind carries the current selection across (chain → failover keeps a,b in order)")
    func switchingKindCarriesSelection() {
        let current = Core.ProxyRoutingMode.chain([a, b])
        let switched = RoutingModeKind.failover.mode(carrying: current.orderedServerIDs)
        #expect(switched == .failover([a, b]))
    }

    @Test("toggling a member on appends it, preserving click order (meaningful for chain hop order)")
    func toggleAppendsInOrder() {
        var mode = Core.ProxyRoutingMode.chain([])
        mode = mode.togglingMember(b, included: true)
        mode = mode.togglingMember(a, included: true)
        mode = mode.togglingMember(c, included: true)
        #expect(mode == .chain([b, a, c]))
    }

    @Test("toggling an already-selected member on is idempotent (no duplicate)")
    func toggleOnIsIdempotent() {
        let mode = Core.ProxyRoutingMode.failover([a, b]).togglingMember(a, included: true)
        #expect(mode == .failover([a, b]))
    }

    @Test("toggling a member off removes exactly it, keeping the rest in order")
    func toggleOffRemoves() {
        let mode = Core.ProxyRoutingMode.loadBalance([a, b, c]).togglingMember(b, included: false)
        #expect(mode == .loadBalance([a, c]))
    }

    @Test("toggling on the single mode is a no-op (single has no member set)")
    func toggleOnSingleIsNoOp() {
        let mode = Core.ProxyRoutingMode.single.togglingMember(a, included: true)
        #expect(mode == .single)
    }
}

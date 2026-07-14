import Core

/// UI 用的路由模式「种类」：把带关联值的 `Core.ProxyRoutingMode` 拍平成一个可放进 SwiftUI
/// Picker 的无参枚举，并在种类之间切换时**保留已选的上游顺序**（切 single↔chain 不丢选择）。
/// 纯值逻辑，住在 AppFeature 方便单测；View 只管把它绑到控件。
public enum RoutingModeKind: String, Sendable, Equatable, CaseIterable {
    case single
    case chain
    case failover
    case loadBalance

    public init(_ mode: Core.ProxyRoutingMode) {
        switch mode {
        case .single: self = .single
        case .chain: self = .chain
        case .failover: self = .failover
        case .loadBalance: self = .loadBalance
        }
    }

    /// 用给定的（已选）上游顺序组装回一个 `Core.ProxyRoutingMode`。single 忽略列表。
    public func mode(carrying ids: [Core.ProxyServerID]) -> Core.ProxyRoutingMode {
        switch self {
        case .single: .single
        case .chain: .chain(ids)
        case .failover: .failover(ids)
        case .loadBalance: .loadBalance(ids)
        }
    }
}

public extension Core.ProxyRoutingMode {
    /// 该模式携带的有序上游 id（single 为空）。
    var orderedServerIDs: [Core.ProxyServerID] {
        switch self {
        case .single: []
        case .chain(let ids), .failover(let ids), .loadBalance(let ids): ids
        }
    }

    /// 在选中集合里增/删一个 id 并保留原顺序，组装出**同一种类**的新模式：
    /// - 加：不在集合里才 append（保留点击顺序，对链的跳序有意义）。
    /// - 删：移除该 id。
    /// single 没有成员集合，原样返回。
    func togglingMember(_ id: Core.ProxyServerID, included: Bool) -> Core.ProxyRoutingMode {
        let kind = RoutingModeKind(self)
        guard kind != .single else { return self }
        var ids = orderedServerIDs
        if included {
            if !ids.contains(id) { ids.append(id) }
        } else {
            ids.removeAll { $0 == id }
        }
        return kind.mode(carrying: ids)
    }
}

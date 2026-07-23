/// 透明代理会话的最新控制意图。NetworkExtension 操作会跨越多个 `await`，因此执行方不能只在
/// 开始时检查一次授权；每次恢复后都要用 ticket 确认自己仍代表最新意图。
public enum ProxySessionIntent: Sendable, Equatable {
    case running
    case stopped
    case restarting
    case resetting
}

public struct ProxySessionIntentTicket: Sendable, Equatable {
    public let revision: UInt64
    public let intent: ProxySessionIntent
}

/// 纯值语义世代协调器。每个新请求都会使旧 ticket 失效；restart/reset 完成后分别归一为
/// running/stopped，但不伪造一个新请求世代。
public struct ProxySessionIntentCoordinator: Sendable, Equatable {
    public private(set) var revision: UInt64 = 0
    public private(set) var intent: ProxySessionIntent = .stopped

    public init() {}

    public var currentTicket: ProxySessionIntentTicket {
        ProxySessionIntentTicket(revision: revision, intent: intent)
    }

    @discardableResult
    public mutating func request(_ intent: ProxySessionIntent) -> ProxySessionIntentTicket {
        revision &+= 1
        self.intent = intent
        return currentTicket
    }

    public func isCurrent(_ ticket: ProxySessionIntentTicket) -> Bool {
        ticket == currentTicket
    }

    public mutating func complete(_ ticket: ProxySessionIntentTicket) {
        guard isCurrent(ticket) else { return }
        switch ticket.intent {
        case .restarting:
            intent = .running
        case .resetting:
            intent = .stopped
        case .running, .stopped:
            break
        }
    }
}

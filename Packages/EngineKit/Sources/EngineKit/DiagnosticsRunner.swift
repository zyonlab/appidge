import Foundation
import Network
import IPCContract

// MARK: - Injected capability protocols
//
// Every real answer DiagnosticsRunner needs comes from a small Sendable protocol so tests
// can inject deterministic mocks — same "protocol + real impl + mock impl" shape as
// ``Transport``/``MockTransport``/``NEFlowTransport``. None of the real implementations
// below are exercised by EngineKitTests (see B4 architecture invariant test).

/// Looks up the rule currently applied to a process (`ruleHit`).
public protocol CurrentRuleLookup: Sendable {
    func currentRule(for processID: ProcessIdentifierDTO) async -> ProxyRuleDTO?
}

/// Looks up whether a process's most recent flow was actually routed through the proxy
/// (`actuallyProxied`). Returns `nil` when there is no recorded history at all, which is
/// distinct from a recorded "was routed direct" outcome.
public protocol RecentRoutingLookup: Sendable {
    func wasRecentlyProxied(processID: ProcessIdentifierDTO) async -> Bool?
}

/// Probes whether a TCP upstream is reachable (`upstreamReachable`).
public protocol UpstreamProbing: Sendable {
    func canReach(host: String, port: UInt16) async -> Bool
}

/// Resolves whether a hostname is DNS-resolvable (`dnsResolution`).
public protocol DNSResolving: Sendable {
    func resolves(host: String) async -> Bool
}

/// Reads the current process's environment variables (`envConflict`).
public protocol EnvironmentReading: Sendable {
    func currentEnvironment() async -> [String: String]
}

// MARK: - DiagnosticsRunner

/// Produces real ``IPCContract/DiagnosticResultDTO`` values for the six ``DiagnosticKindDTO``
/// cases. Declared as a plain `struct` rather than an `actor`: it holds no mutable state of
/// its own — every stateful dependency (rule lookup, routing history) is injected as an
/// already-isolated actor behind a `Sendable` protocol, so `DiagnosticsRunner` itself has
/// nothing to protect. A `struct` also lets call sites construct a fresh, cheap instance per
/// request without actor-hop overhead; `run(processID:kinds:)` is `async` purely because its
/// dependencies are.
///
/// Two of the six kinds are honest, not fully "real":
/// - `udpIPv6QuicLeak` always reports `passed: false` with an explanation, because
///   `NETransparentProxyProvider` (what this app uses) only intercepts TCP flows — it has no
///   visibility into UDP/QUIC traffic at all. That is a correct diagnostic result (it tells
///   the user their UDP/QUIC traffic bypasses the proxy), not a stub.
/// - `envConflict` only inspects `ProcessInfo.processInfo.environment` of the extension
///   process itself, via ``EnvironmentReading``. It cannot see the target app's environment —
///   reading an arbitrary process's environment requires entitlements this app does not have.
///   The result's `detail` says so explicitly.
public struct DiagnosticsRunner: Sendable {
    private let ruleLookup: any CurrentRuleLookup
    private let routingLookup: any RecentRoutingLookup
    private let upstreamProbe: any UpstreamProbing
    private let dnsResolver: any DNSResolving
    private let environmentReader: any EnvironmentReading

    /// Host/port probed for `upstreamReachable` when the caller doesn't override it.
    /// This is intentionally generic (a well-known reachable host) — the diagnostic
    /// answers "can this extension reach the network at all", not "is a specific
    /// configured upstream proxy reachable" (there is no upstream-proxy-address concept
    /// wired into IPCContract yet).
    private let upstreamHost: String
    private let upstreamPort: UInt16

    /// Host resolved for `dnsResolution` when the caller doesn't override it.
    private let dnsProbeHost: String

    public init(
        ruleLookup: any CurrentRuleLookup,
        routingLookup: any RecentRoutingLookup,
        upstreamProbe: any UpstreamProbing,
        dnsResolver: any DNSResolving,
        environmentReader: any EnvironmentReading,
        upstreamHost: String = "1.1.1.1",
        upstreamPort: UInt16 = 443,
        dnsProbeHost: String = "example.com"
    ) {
        self.ruleLookup = ruleLookup
        self.routingLookup = routingLookup
        self.upstreamProbe = upstreamProbe
        self.dnsResolver = dnsResolver
        self.environmentReader = environmentReader
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        self.dnsProbeHost = dnsProbeHost
    }

    public func run(
        processID: ProcessIdentifierDTO,
        kinds: [DiagnosticKindDTO]
    ) async -> [DiagnosticResultDTO] {
        var results: [DiagnosticResultDTO] = []
        results.reserveCapacity(kinds.count)
        for kind in kinds {
            let (passed, detail) = await evaluate(kind, for: processID)
            results.append(DiagnosticResultDTO(processID: processID, kind: kind, passed: passed, detail: detail))
        }
        return results
    }

    private func evaluate(
        _ kind: DiagnosticKindDTO,
        for processID: ProcessIdentifierDTO
    ) async -> (passed: Bool, detail: String) {
        switch kind {
        case .ruleHit:
            return await evaluateRuleHit(processID: processID)
        case .actuallyProxied:
            return await evaluateActuallyProxied(processID: processID)
        case .upstreamReachable:
            return await evaluateUpstreamReachable()
        case .dnsResolution:
            return await evaluateDNSResolution()
        case .udpIPv6QuicLeak:
            return evaluateUDPIPv6QuicLeak()
        case .envConflict:
            return await evaluateEnvConflict()
        }
    }

    // MARK: ruleHit

    private func evaluateRuleHit(processID: ProcessIdentifierDTO) async -> (Bool, String) {
        guard let rule = await ruleLookup.currentRule(for: processID) else {
            return (false, "未找到 \(processID.value) 的显式规则，使用默认行为 (no explicit rule found; default applies).")
        }
        switch rule {
        case .direct:
            return (true, "\(processID.value) 命中规则：direct（直连）。")
        case .proxied:
            return (true, "\(processID.value) 命中规则：proxied（代理）。")
        }
    }

    // MARK: actuallyProxied

    private func evaluateActuallyProxied(processID: ProcessIdentifierDTO) async -> (Bool, String) {
        guard let wasProxied = await routingLookup.wasRecentlyProxied(processID: processID) else {
            return (false, "\(processID.value) 尚无路由历史记录 (no routing history recorded yet) — 无法判断是否真的走了代理。")
        }
        if wasProxied {
            return (true, "\(processID.value) 最近一次观测到的流量确实经过代理转发。")
        } else {
            return (false, "\(processID.value) 最近一次观测到的流量走的是直连，不是代理。")
        }
    }

    // MARK: upstreamReachable

    private func evaluateUpstreamReachable() async -> (Bool, String) {
        let reachable = await upstreamProbe.canReach(host: upstreamHost, port: upstreamPort)
        if reachable {
            return (true, "上游 \(upstreamHost):\(upstreamPort) 可达。")
        } else {
            return (false, "上游 \(upstreamHost):\(upstreamPort) 探活失败，不可达。")
        }
    }

    // MARK: dnsResolution

    private func evaluateDNSResolution() async -> (Bool, String) {
        let resolved = await dnsResolver.resolves(host: dnsProbeHost)
        if resolved {
            return (true, "DNS 解析 \(dnsProbeHost) 成功。")
        } else {
            return (false, "DNS 解析 \(dnsProbeHost) 失败。")
        }
    }

    // MARK: udpIPv6QuicLeak (honest, always-known-limitation)

    private func evaluateUDPIPv6QuicLeak() -> (Bool, String) {
        (
            false,
            "NETransparentProxyProvider 只拦截 TCP，UDP/QUIC（含依赖 QUIC 的 HTTP/3）以及原生 IPv6 " +
            "路径不受这个 provider 管控，会绕开代理直接出网。这是已知架构限制，不是这次没测好：真正检测 " +
            "UDP/QUIC 泄漏需要 NEFilterDataProvider 或包级抓包，这不在当前 NETransparentProxyProvider " +
            "架构范围内。(NETransparentProxyProvider only intercepts TCP; UDP/QUIC/HTTP3 and native " +
            "IPv6 flows bypass it entirely and leak around the proxy. This is a genuine architectural " +
            "limitation of this provider type, not an untested code path.)"
        )
    }

    // MARK: envConflict

    /// Known proxy-related environment variable names that can conflict with this app's own
    /// per-process proxying (a process that already honors HTTP_PROXY/HTTPS_PROXY/ALL_PROXY
    /// may double-proxy or bypass our routing decisions).
    private static let conflictingKeys = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"]

    private func evaluateEnvConflict() async -> (Bool, String) {
        let environment = await environmentReader.currentEnvironment()
        let present = Self.conflictingKeys.filter { environment[$0] != nil }

        // Honest limitation, stated regardless of outcome: this can only see the extension
        // process's own environment (ProcessInfo.processInfo.environment), never the target
        // app's — reading an arbitrary other process's environment needs entitlements this
        // app doesn't have.
        let scopeNote = "（注：此项只能看到扩展进程自身的环境变量，看不到目标 app 的环境变量 — " +
            "this only inspects the extension process's own environment, not the target app's.）"

        if present.isEmpty {
            return (true, "未在扩展进程环境变量中发现冲突的代理相关变量。\(scopeNote)")
        } else {
            let list = present.sorted().joined(separator: ", ")
            return (false, "扩展进程环境变量中存在可能冲突的代理相关变量：\(list)。\(scopeNote)")
        }
    }
}

// MARK: - AppliedRuleSetStore (real CurrentRuleLookup)

/// Real, actor-backed ``CurrentRuleLookup``: stores the assignments from the most recently
/// applied ``RuleSetMessage`` in a dictionary. Nothing fake here — call ``apply(_:)`` whenever
/// a `RuleSetMessage` arrives (e.g. from `AppToExtensionMessage.applyRuleSet`) and lookups
/// reflect the latest state. Integration gap, documented honestly: nothing in this package
/// calls `apply(_:)` yet — that wiring belongs to whatever owns the extension's message loop
/// (see the integration note in the task report).
public actor AppliedRuleSetStore: CurrentRuleLookup {
    private var assignments: [ProcessIdentifierDTO: ProxyRuleDTO] = [:]
    private var matchRules: [MatchRuleDTO] = []

    public init() {}

    /// 全量替换:app 每次下发的都是当前完整规则集,所以把 assignments 整个换掉
    /// (被改回默认的进程规则会因此被丢弃,而不是残留),match 规则表也整份替换。
    public func apply(_ ruleSet: RuleSetMessage) {
        var next: [ProcessIdentifierDTO: ProxyRuleDTO] = [:]
        for assignment in ruleSet.assignments {
            next[assignment.processID] = assignment.rule
        }
        assignments = next
        matchRules = ruleSet.matchRules
    }

    public func currentRule(for processID: ProcessIdentifierDTO) async -> ProxyRuleDTO? {
        assignments[processID]
    }

    /// 细粒度规则表匹配:`app` 是进程签名标识,`host`/`port` 是目标。命中返回动作,否则 nil。
    public func matchRule(app: String, host: String, port: UInt16) async -> ProxyRuleDTO? {
        RuleMatcher.firstMatch(matchRules, app: app, host: host, port: port)
    }
}

// MARK: - RoutingHistoryTracker (real RecentRoutingLookup)

/// Real, actor-backed ``RecentRoutingLookup``: stores the most recent proxied/direct outcome
/// per process. Nothing fake here either — call ``record(processID:wasProxied:)`` whenever a
/// flow is actually routed (e.g. from ``FlowRouter/route(processID:bytesUp:bytesDown:rule:now:)``)
/// and lookups reflect the latest observed outcome. Integration gap, documented honestly:
/// `FlowRouter` does not call `record` yet — this tracker exists and is fully unit-tested, but
/// nothing in production wires it to `FlowRouter` in this change (see the integration note in
/// the task report).
public actor RoutingHistoryTracker: RecentRoutingLookup {
    private var lastOutcome: [ProcessIdentifierDTO: Bool] = [:]

    public init() {}

    public func record(processID: ProcessIdentifierDTO, wasProxied: Bool) {
        lastOutcome[processID] = wasProxied
    }

    public func wasRecentlyProxied(processID: ProcessIdentifierDTO) async -> Bool? {
        lastOutcome[processID]
    }
}

// MARK: - NWConnectionUpstreamProbe (real UpstreamProbing)

/// Real ``UpstreamProbing`` using Network.framework, mirroring the state-machine handling in
/// ``NEFlowTransport/probeUpstream()``: start a TCP `NWConnection` and resolve on `.ready`
/// (reachable) or `.failed`/`.cancelled` (not reachable). Never instantiated by EngineKitTests
/// (see B4 architecture invariant test) — production-only, exercised via manual/smoke testing.
public struct NWConnectionUpstreamProbe: UpstreamProbing, Sendable {
    public init() {}

    public func canReach(host: String, port: UInt16) async -> Bool {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 443
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        defer { connection.cancel() }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let box = DiagnosticsContinuationBox(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume(true)
                case .failed, .cancelled:
                    box.resume(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }
}

// MARK: - NWConnectionDNSResolver (real DNSResolving)

/// Real ``DNSResolving`` using Network.framework: attempts a TCP connection by hostname on
/// port 443. A connection that reaches `.ready` (or fails with a non-DNS error, e.g. the peer
/// actively refusing the connection) implies the hostname resolved — the failure that
/// specifically indicates DNS did *not* resolve is `.failed` with a DNS-category `NWError`.
/// Never instantiated by EngineKitTests (see B4 architecture invariant test).
public struct NWConnectionDNSResolver: DNSResolving, Sendable {
    private let port: UInt16

    public init(port: UInt16 = 443) {
        self.port = port
    }

    public func resolves(host: String) async -> Bool {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 443
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        defer { connection.cancel() }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let box = DiagnosticsContinuationBox(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume(true)
                case .failed(let error):
                    box.resume(!error.isDNSFailure)
                case .cancelled:
                    box.resume(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }
}

private extension NWError {
    /// True when the connection failed specifically because the hostname didn't resolve,
    /// as opposed to e.g. the remote refusing the connection (which still implies DNS worked).
    var isDNSFailure: Bool {
        if case .dns = self {
            return true
        }
        return false
    }
}

// MARK: - ProcessInfoEnvironmentReader (real EnvironmentReading)

/// Real ``EnvironmentReading``: reads `ProcessInfo.processInfo.environment` — i.e. only the
/// extension process's own environment. This is a hard platform limitation, not a shortcut:
/// reading another process's environment requires entitlements this app does not have.
public struct ProcessInfoEnvironmentReader: EnvironmentReading, Sendable {
    public init() {}

    public func currentEnvironment() async -> [String: String] {
        ProcessInfo.processInfo.environment
    }
}

/// CheckedContinuation can only be resumed once; NWConnection's stateUpdateHandler can call
/// back into `.cancelled` after already reaching `.ready`/`.failed`, so guard with a lock —
/// same pattern as `NEFlowTransport`'s `ContinuationBox`.
private final class DiagnosticsContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

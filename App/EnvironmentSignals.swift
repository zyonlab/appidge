import Foundation
import Core
import AppFeature

/// 环境信号(代理环境探测 + 本地代理身份发现)的编排,从 `AppidgeApp` 拆出的独立命名空间。
///
/// 两个信号都是「探测 → dispatch,reducer 差分守卫」的纯回灌,合在一起周期对账:
/// - 代理环境(系统代理 / 环境变量 / utun):UI 据此解释盲区,并驱动 TUN 冲突警示的时效性。
/// - 本地代理身份(active 回环上游端口的监听进程):这是追上「7890 背后监听者易主」的唯一
///   路径——用户把代理软件从 xray 换成 Clash Party(mihomo)时 appidge 配置一字不变,挂在
///   applyProxyConfig 后的那次发现不会重跑,旧身份让新代理进程漏出观测档、被规则层全量接管
///   (全机代理吞吐二次过扩展 pump,0.2.12/24/30 三次事故同根因)。
enum EnvironmentSignals {

    /// 探测两个信号并回灌 store(进入 / 回前台 / 周期 tick 共用)。
    @MainActor
    static func refresh(store: Store) async {
        let environment = await SystemProxyEnvironmentProbe().probe()
        store.dispatch(.proxyEnvironmentDetected(environment))
        let action = await resolveProcessOriginExclusions(
            servers: Array(store.state.proxyServers.values),
            activeID: store.state.activeProxyServerID,
            using: LibprocSecCodeProcessIdentityResolver()
        )
        store.dispatch(action)
    }

    /// 已启动的周期循环——幂等闸。调用点在主窗口的 `.task` 里,而这个循环是游离 Task、
    /// 不随视图取消:窗口关了再开会重跑 `.task`,没有闸每次重开就多叠一个循环。
    @MainActor private static var periodicRefreshTask: Task<Void, Never>?

    /// 30 秒周期对账循环(随 app 生命周期常驻,重复调用幂等)。无变化时零副作用,
    /// 探测本身只是 getifaddrs + CFNetwork 快照 + libproc 单端口查询,代价可忽略。
    @MainActor
    static func startPeriodicRefresh(store: Store) {
        guard periodicRefreshTask == nil else { return }
        periodicRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await refresh(store: store)
            }
        }
    }

    /// active 上游若指向本机(如用户配的是本地 xray/mihomo),查出它的签名标识 + 可执行文件
    /// 路径、包成 `.proxyProcessIdentitiesResolved` 供 store 回灌——转发环硬化的「来源进程
    /// 自动排除」(见 LocalProxyOriginDiscovery)。applyProxyConfig 下发后与周期对账两处共用。
    static func resolveProcessOriginExclusions(
        servers: [Core.ProxyServer], activeID: Core.ProxyServerID?, using resolver: any LocalProcessIdentityResolving
    ) async -> Core.Action {
        let discoveryState = Core.AppState(
            proxyServers: Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) }),
            activeProxyServerID: activeID
        )
        let discovery = await LocalProxyOriginDiscovery.discover(state: discoveryState, using: resolver)
        return .proxyProcessIdentitiesResolved(discovery)
    }
}

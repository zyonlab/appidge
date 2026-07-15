import Darwin
import Security

/// 本机代理进程签名标识解析的可测试接缝——防转发环第二正交维度(来源进程身份)里,
/// 「查出监听某本地端口的进程、取它的代码签名标识」这一环。真实实现用 libproc 查监听 fd
/// + SecCode 取签名标识;测试用 ``MockLocalProcessIdentityResolver``。
///
/// 与 ``ProxyReachabilityProbe`` 同一套分层意图:这里只放协议 + 真实实现 + mock,
/// 「什么时候该查」的编排逻辑在 ``LocalProxyOriginDiscovery``。
public protocol LocalProcessIdentityResolving: Sendable {
    /// 查出监听 `port`(TCP,127.0.0.1/::1 本地回环)的进程的代码签名标识;
    /// 查不到监听者、或该进程未签名/取不到标识,返回 nil——这是预期情形之一,不是错误,
    /// 调用方不应把 nil 当失败处理(未签名的本地代理进程很常见)。
    func signingIdentifier(forListeningPort port: UInt16) async -> String?
}

/// 测试专用 mock:按端口预置签名标识,记录被查询过的端口(按调用顺序)供编排层测试断言。
/// 未预置的端口返回 nil,跟真实实现「查不到就是 nil」的语义一致,不会让「忘了预置」假装命中。
/// 跟 ``MockProxyReachabilityProbe`` 一样用 `actor` 做并发安全,不需要额外的锁/Foundation 依赖。
public actor MockLocalProcessIdentityResolver: LocalProcessIdentityResolving {
    private let scripted: [UInt16: String]
    /// 按发生顺序累积的、被查询过的端口,供测试断言「用对的端口查了/没有多查」。
    public private(set) var calls: [UInt16] = []

    /// - Parameter scripted: 以端口为 key 的脚本化签名标识表,缺省空表(一律 nil)。
    public init(scripted: [UInt16: String] = [:]) {
        self.scripted = scripted
    }

    public func signingIdentifier(forListeningPort port: UInt16) async -> String? {
        calls.append(port)
        return scripted[port]
    }
}

/// 生产路径:遍历所有进程的 fd 表(libproc)找到监听给定 TCP 端口的 pid,
/// 再用 SecCode 取它的签名标识。跟 ``KeychainCredentialStore``/``NEFlowTransport`` 一样,
/// 这个真实实现**不进自动化测试**——依赖真实系统进程表与代码签名状态,结果随机器环境
/// (跑着哪些进程、它们签没签名)而变,CI 里跑不出稳定断言。
///
/// 标 `@unchecked Sendable`:类型本身无可变存储状态(仅一个空 `init`),每次调用都是独立的
/// 一次性系统调用(libproc 读进程表快照 + Security 查签名),没有跨调用共享的可变状态需要保护。
public final class LibprocSecCodeProcessIdentityResolver: LocalProcessIdentityResolving, @unchecked Sendable {
    public init() {}

    public func signingIdentifier(forListeningPort port: UInt16) async -> String? {
        guard let pid = Self.findListeningPid(port: port) else { return nil }
        return Self.signingIdentifier(forPid: pid)
    }

    // MARK: - libproc:找监听给定端口的 pid

    /// 遍历所有 pid,找一个 fd 表里存在「TCP + LISTEN 态 + 本地端口匹配」socket 的进程。
    /// 查不到、或某个 pid 的 fd 表读取失败(权限不足/进程已退出的竞态)一律跳过该 pid,
    /// 不中断整体遍历——防止个别不可读进程导致整次查询提前失败。
    private static func findListeningPid(port: UInt16) -> pid_t? {
        // 先探需要多大的缓冲区(传 nil/0 是 proc_listallpids 的标准用法),
        // 再按「探到的大小 + 一点余量」实际取一次——余量应对两次调用之间新起的进程。
        let neededBytes = proc_listallpids(nil, 0)
        guard neededBytes > 0 else { return nil }
        let capacity = Int(neededBytes) / MemoryLayout<pid_t>.stride + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
        guard bytes > 0 else { return nil }
        let count = min(pids.count, Int(bytes) / MemoryLayout<pid_t>.stride)

        for pid in pids.prefix(count) where pid > 0 {
            if listeningPort(ofPid: pid) == port {
                return pid
            }
        }
        return nil
    }

    /// 该 pid 的 fd 表里,若存在一个处于 LISTEN 态的 TCP socket,返回它的本地端口;
    /// 否则(无 socket fd、无 LISTEN 态、读取失败/无权限)返回 nil。
    private static func listeningPort(ofPid pid: pid_t) -> UInt16? {
        let fdBufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard fdBufferSize > 0 else { return nil }
        let fdCount = Int(fdBufferSize) / MemoryLayout<proc_fdinfo>.stride
        guard fdCount > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
        let actualSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, fdBufferSize)
        guard actualSize > 0 else { return nil }
        let actualCount = min(fdCount, Int(actualSize) / MemoryLayout<proc_fdinfo>.stride)

        for fd in fds.prefix(actualCount) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = proc_pidfdinfo(
                pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.stride)
            )
            guard infoSize == Int32(MemoryLayout<socket_fdinfo>.stride) else { continue }
            guard info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // insi_lport 是网络字节序塞进一个 host-order 的 Int 里;先截断取低 16 位,
            // 再当大端序解读才是真正的端口号(常见于 lsof/netstat 一类工具的实现)。
            return UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
        }
        return nil
    }

    // MARK: - SecCode:pid → 签名标识

    /// 用 SecCode 取该 pid 当前运行进程的签名标识(`kSecCodeInfoIdentifier`)。
    /// 未签名/ad-hoc 签名/查询失败一律返回 nil(预期情形,不是错误)。
    private static func signingIdentifier(forPid pid: pid_t) -> String? {
        var guestCode: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
              let guestCode else { return nil }

        // SecCode → SecStaticCode 的规范转换方式:直接强转不是文档化的路径,
        // SecCodeCopyStaticCode 才是。
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guestCode, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var signingInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo
        )
        guard infoStatus == errSecSuccess, let info = signingInfo as? [String: Any] else { return nil }

        return info[kSecCodeInfoIdentifier as String] as? String
    }
}

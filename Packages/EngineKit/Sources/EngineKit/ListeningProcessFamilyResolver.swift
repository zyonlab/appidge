import Darwin
import Foundation

/// ``SelfForwardLoopDetector`` 的系统调用侧:采样进程家族信息(pid → ppid/pgid)、
/// 遍历进程表找「监听给定 TCP 端口的进程」。跟 `AppFeature.LibprocSecCodeProcessIdentityResolver`
/// 一个谱系,但跑在扩展进程里(root,对别人的进程表可见度比沙盒 app 侧更好——app 侧解析失败的
/// 场景正是这里要兜的)。同一纪律:真实实现**不进自动化测试**(结果随机器进程表而变),
/// 判定逻辑全部在可注入 ``ProcessFamily`` 值的 ``SelfForwardLoopDetector`` 里单测。
///
/// 与 app 侧实现的一个刻意差异:`listeningPorts(ofPid:)` 收集该进程**所有** LISTEN 态端口再查
/// 是否包含目标端口——app 侧只取第一个 LISTEN fd 就返回,xray 常见的「SOCKS + HTTP 双端口」
/// 会因 fd 顺序漏判(那是 app 侧待修的独立缺口,这里不重复它)。
public enum ListeningProcessFamilyResolver {

    /// 该 pid 的家族信息(ppid/pgid 经 `proc_pidinfo(PROC_PIDTBSDINFO)`)。进程已退出/查询失败
    /// 返回 nil——调用方按 fail-open 处理。
    public static func family(ofPid pid: Int32) -> ProcessFamily? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            // 进程存在但 TBSDINFO 拿不到(罕见):退化为只有 pid 的家族——同 pid 判定仍然成立。
            return ProcessFamily(pid: pid)
        }
        return ProcessFamily(
            pid: pid, parentPid: Int32(bitPattern: info.pbi_ppid), groupID: Int32(bitPattern: info.pbi_pgid)
        )
    }

    /// 遍历所有 pid,找监听 `port`(TCP LISTEN 态,任意本机地址)的进程并返回其家族信息。
    /// 全表遍历是毫秒级(数百进程 × fd 表),调用方负责异步执行 + TTL 缓存
    /// (``SelfForwardLoopDetector`` 的 `portsToResolve`/`storeListener` 契约),不进转发热路径。
    /// 个别 pid 的 fd 表不可读(权限/退出竞态)跳过不中断,查不到返回 nil(负缓存同样有效)。
    public static func listenerFamily(forPort port: UInt16) -> ProcessFamily? {
        let neededBytes = proc_listallpids(nil, 0)
        guard neededBytes > 0 else { return nil }
        let capacity = Int(neededBytes) / MemoryLayout<pid_t>.stride + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
        guard bytes > 0 else { return nil }
        let count = min(pids.count, Int(bytes) / MemoryLayout<pid_t>.stride)

        for pid in pids.prefix(count) where pid > 0 {
            if listeningPorts(ofPid: pid).contains(port) {
                return family(ofPid: pid)
            }
        }
        return nil
    }

    /// 该 pid 的 fd 表里全部处于 LISTEN 态的 TCP 本地端口(空集 = 无监听/不可读)。
    private static func listeningPorts(ofPid pid: pid_t) -> Set<UInt16> {
        let fdBufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard fdBufferSize > 0 else { return [] }
        let fdCount = Int(fdBufferSize) / MemoryLayout<proc_fdinfo>.stride
        guard fdCount > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
        let actualSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, fdBufferSize)
        guard actualSize > 0 else { return [] }
        let actualCount = min(fdCount, Int(actualSize) / MemoryLayout<proc_fdinfo>.stride)

        var ports: Set<UInt16> = []
        for fd in fds.prefix(actualCount) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = proc_pidfdinfo(
                pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.stride)
            )
            guard infoSize == Int32(MemoryLayout<socket_fdinfo>.stride) else { continue }
            guard info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // insi_lport 是网络字节序塞进 host-order Int:截低 16 位再按大端解读
            // (同 app 侧解析器与 lsof/netstat 的读法)。
            ports.insert(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
        }
        return ports
    }
}

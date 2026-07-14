/// 主动式「转发环」检测器 —— 纯值类型、确定性、内部不读时钟(时间戳一律由调用方传入)。
///
/// 转发环:我们捕获一条连接 → 重定向到本地代理 → 代理又发起同一条连接 → 再次被我们捕获……如此往复。
/// Proxifier 会侦测并告警;这里给扩展一个可逐条喂入「捕获」的确定性检测器:当同一 `signature` 在
/// `windowSeconds` 窗口内累计到达 `threshold` 次,即判定成环并返回 true,好让 app 通知用户。
///
/// `signature` 是调用方自行拼装的不透明字符串(例如「上游端点 + 目的地」),本类型不解释其含义,只按
/// 字符串是否相同来分桶。命中后会清空该 signature 的窗口,使每一轮突发只报一次(而非越过阈值后每次
/// 调用都 true 刷屏)。
///
/// 无 I/O、不读时钟,是 `Sendable` 值类型:可在任意隔离域内使用;拷贝彼此独立、不共享可变引用
/// (契合 CLAUDE.md §2 的线程隔离约束)。
public struct LoopDetector: Sendable {

    /// 判定成环所需的「窗口内累计次数」。构造时钳到下限 1。
    private let threshold: Int
    /// 滑动窗口长度(秒);「年龄」≥ 窗口的旧时间戳视为窗外并剔除。
    private let windowSeconds: Double
    /// 每个 signature 各自的滑动窗口:窗内「捕获」时间戳,按记录顺序(即升序)追加。
    private var timestamps: [String: [Double]] = [:]

    /// - Parameters:
    ///   - threshold: 窗口内累计到多少次判定成环;≤ 0 会被钳到 1(误配时退化为「每条捕获都命中」,
    ///     而非产生「计数永远满足」之类的混乱语义)。
    ///   - windowSeconds: 滑动窗口长度(秒)。
    public init(threshold: Int = 5, windowSeconds: Double = 1.0) {
        self.threshold = max(1, threshold)
        self.windowSeconds = windowSeconds
    }

    /// 记录一次「捕获」。先剔除该 signature 窗外(年龄 ≥ `windowSeconds`)的旧时间戳,再追加 `now`;
    /// 若窗内累计达到 `threshold` 次,则判定成环、清空该 signature 的窗口并返回 true(每轮突发只报一
    /// 次),否则返回 false。
    /// - Parameters:
    ///   - signature: 调用方拼装的不透明标识(如「上游端点 + 目的地」)。
    ///   - now: 本次捕获的时间戳(秒),由调用方传入(便于确定性测试与跨隔离域复用)。
    /// - Returns: 本次记录是否使该 signature 在窗口内达到阈值(即判定成环)。
    public mutating func record(signature: String, now: Double) -> Bool {
        // 窗口边界排他:年龄恰好等于 windowSeconds 的记录判为窗外(t <= cutoff 即剔除)。
        let cutoff = now - windowSeconds
        var window = timestamps[signature] ?? []
        window.removeAll { $0 <= cutoff }
        window.append(now)

        if window.count >= threshold {
            // 命中即清空该 signature:下一轮需重新积累一整个突发才会再次告警。
            timestamps.removeValue(forKey: signature)
            return true
        }

        timestamps[signature] = window
        return false
    }
}

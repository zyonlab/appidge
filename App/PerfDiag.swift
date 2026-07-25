import Foundation
import AppFeature

/// **性能埋点**（临时诊断用）。回答一个具体问题：接管流量跑起来后，主线程到底忙在哪。
///
/// 为什么不用 os_signpost / os_log：这个 app 的 os_log 输出被系统当作 `<private>` 隐藏，
/// 终端一条都读不到（`ExtDiag.swift` 开头记着同一件事，那也是它改走 App Group 的原因）。
/// 而 Debug 构建下系统扩展不会转发流量，本地压根产生不了负载——只能出包实跑再读文件。
///
/// 三条设计约束，缺一这套埋点自己就会变成被测对象：
/// 1. **聚合，不逐事件记录**：只累加 次数/总耗时/最大耗时，每 `flushInterval` 秒落一行汇总。
///    逐次写盘正是 `ConnectionLogFileStore` 曾经踩过的坑。
/// 2. **热路径只做一次时钟读取 + 一次字典累加**，无分配、无格式化。
/// 3. **可一键关**：`PerfDiag.isEnabled = false` 后所有 `measure` 退化成直接调用闭包。
///
/// 输出：`~/Library/Application Support/appidge/perf.jsonl`，每行一个 JSON 汇总窗口。
enum PerfDiag {
    /// 总开关。诊断版打开；确认完瓶颈后连同本文件一起删掉，或改成 false 发布。
    nonisolated(unsafe) static var isEnabled = true

    /// 汇总落盘间隔。10s 够密（一次运行能拿到几十个窗口），又不至于让写盘本身可见。
    private static let flushInterval: TimeInterval = 10

    /// 被测量的位置。加新点就往这里加一个 case——名字直接进 JSON，便于我按名字读。
    enum Site: String, CaseIterable {
        /// 一批连接事件落进 Store（reducer 去重 + 环形缓冲维护），批大小另记。
        case dispatchConnectionBatch = "store.connection_batch"
        /// 连接表每次渲染的 filter + sort（我的静态分析怀疑这是主线程大头）。
        case connectionsTableRows = "view.table_rows"
        /// 状态栏聚合（活动连接数 + 全局上下行）。
        case statusBarAggregates = "view.statusbar_agg"
        /// 菜单栏面板聚合（含 topByThroughput 排序）。
        case menuBarAggregates = "view.menubar_agg"
        /// 流量面板每次渲染的排序。
        case trafficPaneRows = "view.traffic_rows"
        /// 主线程上的同步落盘（JSON 编码 + 原子写）。
        case persistConfiguration = "io.persist_sync"
    }

    // MARK: - 累加器

    private struct Bucket {
        var count = 0
        var totalNanos: UInt64 = 0
        var maxNanos: UInt64 = 0
        /// 仅批量类站点使用：累计处理的条目数，用来算「每条多少 μs」。
        var items = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var buckets: [Site: Bucket] = [:]
    /// 主线程调度延迟样本（毫秒）。反映「主线程被堵了多久」，是判断卡顿最直接的信号。
    nonisolated(unsafe) private static var hitchSamples: [Double] = []
    nonisolated(unsafe) private static var windowStart = DispatchTime.now().uptimeNanoseconds
    nonisolated(unsafe) private static var flushScheduled = false

    private static let flushQueue = DispatchQueue(label: "com.appidge.perfdiag", qos: .utility)

    /// 安装到 AppFeature 的埋点钩子上（AppFeature 不反向依赖 App，故用回调注入），
    /// 并启动主线程响应性采样。在 App 装配时调用一次。
    @MainActor
    static func install() {
        guard isEnabled else { return }
        PerfHooks.onConnectionBatch = { nanos, count in
            record(.dispatchConnectionBatch, nanos: nanos, items: count)
        }
        startMainThreadSampler()
    }

    /// 测量一段同步工作。`items` 给批量站点用（如一批连接事件的条数）。
    /// 关闭时零开销：直接调用闭包，连时钟都不读。
    @discardableResult
    static func measure<T>(_ site: Site, items: Int = 0, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = body()
        record(site, nanos: DispatchTime.now().uptimeNanoseconds &- start, items: items)
        return result
    }

    private static func record(_ site: Site, nanos: UInt64, items: Int) {
        lock.lock()
        var bucket = buckets[site] ?? Bucket()
        bucket.count += 1
        bucket.totalNanos &+= nanos
        bucket.maxNanos = max(bucket.maxNanos, nanos)
        bucket.items += items
        buckets[site] = bucket
        let shouldSchedule = !flushScheduled
        if shouldSchedule { flushScheduled = true }
        lock.unlock()
        if shouldSchedule {
            flushQueue.asyncAfter(deadline: .now() + flushInterval) { flush() }
        }
    }

    // MARK: - 主线程卡顿采样

    /// 启动主线程响应性采样：每 `interval` 秒往主线程投一个空任务，测**实际到达时间与预期的差**。
    /// 差值大 = 主线程当时被占住了。这条比任何单点计时都更能直接回答「UI 线程是不是被堵住」。
    @MainActor
    static func startMainThreadSampler(interval: TimeInterval = 0.25) {
        guard isEnabled else { return }
        Task { @MainActor in
            while !Task.isCancelled {
                let expected = DispatchTime.now().uptimeNanoseconds &+ UInt64(interval * 1_000_000_000)
                try? await Task.sleep(for: .seconds(interval))
                let actual = DispatchTime.now().uptimeNanoseconds
                let lateNanos = actual > expected ? actual &- expected : 0
                // 异步上下文里必须用 scoped 加锁（手动 lock/unlock 在 Swift 6 是错误）。
                lock.withLock { hitchSamples.append(Double(lateNanos) / 1_000_000) }
            }
        }
    }

    // MARK: - 落盘

    private static func flush() {
        lock.lock()
        flushScheduled = false
        let snapshot = buckets
        let hitches = hitchSamples
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds &- windowStart
        buckets.removeAll(keepingCapacity: true)
        hitchSamples.removeAll(keepingCapacity: true)
        windowStart = DispatchTime.now().uptimeNanoseconds
        lock.unlock()

        guard !snapshot.isEmpty || !hitches.isEmpty else { return }

        var sites: [String: Any] = [:]
        for (site, bucket) in snapshot {
            var entry: [String: Any] = [
                "n": bucket.count,
                "total_ms": round(Double(bucket.totalNanos) / 1_000_000 * 100) / 100,
                "max_ms": round(Double(bucket.maxNanos) / 1_000_000 * 100) / 100
            ]
            if bucket.items > 0 { entry["items"] = bucket.items }
            sites[site.rawValue] = entry
        }

        var line: [String: Any] = [
            "window_s": round(Double(elapsedNanos) / 1_000_000_000 * 100) / 100,
            "sites": sites
        ]
        if !hitches.isEmpty {
            let sorted = hitches.sorted()
            line["main_thread_late_ms"] = [
                "n": sorted.count,
                "p50": round(percentile(sorted, 0.50) * 100) / 100,
                "p95": round(percentile(sorted, 0.95) * 100) / 100,
                "max": round((sorted.last ?? 0) * 100) / 100
            ]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        var payload = data
        payload.append(0x0A)
        appendToFile(payload)
    }

    private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * q).rounded())))
        return sorted[index]
    }

    /// 与 `ConnectionLogFileStore` 同样的教训：复用句柄，不要每次 open/close。
    nonisolated(unsafe) private static var handle: FileHandle?

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("appidge", isDirectory: true)
            .appendingPathComponent("perf.jsonl")
    }

    private static func appendToFile(_ payload: Data) {
        let url = fileURL
        if handle == nil {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: payload)
    }
}

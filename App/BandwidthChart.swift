import SwiftUI
import Charts
import Core
import AppFeature

/// 带宽曲线(苹果原生 Swift Charts,对齐 Proxifier 的 Traffic 图)。每秒采一次全局累计字节的增量
/// = 上/下行 bytes/sec,保留最近 `window` 秒,面积图叠加。采样用 1s 定时器(面板常驻底部,开销可忽略)。
struct BandwidthChart: View {
    var store: Store

    @State private var samples: [Sample] = []
    @State private var lastTotals: (up: Int64, down: Int64) = (0, 0)
    @State private var tick = 0

    struct Sample: Identifiable {
        let t: Int
        let dir: String
        let rate: Double        // bytes/sec
        var id: String { "\(t)-\(dir)" }
    }

    private let window = 60
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Chart(samples) { s in
            AreaMark(x: .value("时间", s.t), y: .value("速率", s.rate))
                .foregroundStyle(by: .value("方向", s.dir))
                .interpolationMethod(.monotone)
                .opacity(0.65)
        }
        .chartForegroundStyleScale(["下行": Color.blue, "上行": Color.green])
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(TrafficFormat.rate(v)).font(.caption2) }
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading, spacing: 4)
        .onReceive(timer) { _ in sample() }
    }

    private func sample() {
        let cur = TrafficStatsAggregator.totals(Array(store.state.processes.values))
        let up = max(0, Double(cur.up &- lastTotals.up))
        let down = max(0, Double(cur.down &- lastTotals.down))
        lastTotals = cur
        tick += 1
        samples.append(Sample(t: tick, dir: "下行", rate: down))
        samples.append(Sample(t: tick, dir: "上行", rate: up))
        let cutoff = tick - window
        if cutoff > 0 { samples.removeAll { $0.t <= cutoff } }
    }
}

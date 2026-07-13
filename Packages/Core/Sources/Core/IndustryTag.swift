public enum IndustryTag: String, Sendable, Equatable, Codable, CaseIterable {
    case technology
    case finance
    case gaming
    case productivity
    case unknown
}

/// 行业种子打标：bundle id 前缀 → 行业的种子表，构建成倒排索引（行业 → 一组前缀）后
/// 按最长前缀匹配打标。
///
/// **假设记录**：CLAUDE.md 只给了一行「行业种子打标（薪资倒排）」，没说明真实数据源。
/// 这里先把匹配机制（倒排索引 + 最长前缀）做对、做可测；`placeholder` 只是几条示例种子，
/// 不是真实数据集——真实的「薪资倒排」数据源（大概率是公开薪资/公司数据库按行业反查）
/// 需要人补充，见 PROGRESS.md。
public struct IndustrySeedIndex: Sendable {
    private let invertedIndex: [IndustryTag: [String]]

    public init(seeds: [(prefix: String, industry: IndustryTag)]) {
        var index: [IndustryTag: [String]] = [:]
        for seed in seeds {
            index[seed.industry, default: []].append(seed.prefix)
        }
        self.invertedIndex = index
    }

    public static let placeholder = IndustrySeedIndex(seeds: [
        (prefix: "com.apple.dt.Xcode", industry: .technology),
        (prefix: "com.jetbrains.", industry: .technology),
        (prefix: "com.microsoft.", industry: .productivity),
        (prefix: "com.valvesoftware.", industry: .gaming),
        (prefix: "com.coinbase.", industry: .finance)
    ])

    public func tag(bundleID: String) -> IndustryTag {
        var best: (industry: IndustryTag, prefixLength: Int)?
        for (industry, prefixes) in invertedIndex {
            for prefix in prefixes where bundleID.hasPrefix(prefix) {
                if best == nil || prefix.count > best!.prefixLength {
                    best = (industry, prefix.count)
                }
            }
        }
        return best?.industry ?? .unknown
    }
}

import Testing
@testable import Core

@Suite("IndustrySeedIndex — bundle-id prefix -> industry via inverted index")
struct IndustrySeedIndexTests {

    @Test("longest matching prefix wins")
    func longestPrefixWins() {
        let index = IndustrySeedIndex(seeds: [
            (prefix: "com.example", industry: .productivity),
            (prefix: "com.example.finance", industry: .finance)
        ])
        #expect(index.tag(bundleID: "com.example.finance.ledger") == .finance)
        #expect(index.tag(bundleID: "com.example.notes") == .productivity)
    }

    @Test("no matching prefix falls back to unknown")
    func noMatchFallsBackToUnknown() {
        let index = IndustrySeedIndex(seeds: [(prefix: "com.example", industry: .productivity)])
        #expect(index.tag(bundleID: "org.other.app") == .unknown)
    }

    @Test("placeholder seed set tags a few well-known prefixes")
    func placeholderSeedSetTagsKnownPrefixes() {
        #expect(IndustrySeedIndex.placeholder.tag(bundleID: "com.apple.dt.Xcode") == .technology)
        #expect(IndustrySeedIndex.placeholder.tag(bundleID: "com.unknown.vendor.app") == .unknown)
    }
}

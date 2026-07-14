import Testing
@testable import EngineKit

/// 纯、无状态的「按来源进程排除」判定 —— 每条用例都是对
/// `ProcessOriginExclusion.shouldBypass(sourceIdentifier:ownIdentifiers:)` 的一次 `#expect`。
///
/// 这是转发环硬化的第二道闸，和基于地址的 `UpstreamExclusion` 正交：扩展在
/// `effectiveRule` 里会拿本条 flow 的 `sourceAppSigningIdentifier` 与
/// `{APP_BUNDLE_ID, EXT_BUNDLE_ID}` 先过一遍本判定，命中即强制 `.direct`，在跑每进程
/// 规则表之前。理由——如果一条被捕获的 flow 本就由「我们自己的组件（主 app / 系统扩展）」
/// 发起（典型即扩展→上游的出站腿），再把它代理一次就会自食其尾成环；地址判定在上游为
/// 非回环地址、或多网卡/域名等形态下并不可靠，所以需要这条按「来源身份」而非「目的地址」的
/// 独立守卫。
@Suite("ProcessOriginExclusion —— 按来源进程的转发环硬化判定")
struct ProcessOriginExclusionTests {

    // 测试用的通用占位标识（不使用真实签名/team 信息）。
    private let appID = "com.example.proxyapp"
    private let extID = "com.example.proxyapp.extension"

    // MARK: - 命中 / 未命中（精确匹配）

    @Test("来源正是 app 自身 → 强制直连（bypass）")
    func sourceIsApp() {
        let own: Set<String> = [appID, extID]
        #expect(ProcessOriginExclusion.shouldBypass(sourceIdentifier: appID, ownIdentifiers: own))
    }

    @Test("来源正是系统扩展自身 → 强制直连（bypass）")
    func sourceIsExtension() {
        let own: Set<String> = [appID, extID]
        #expect(ProcessOriginExclusion.shouldBypass(sourceIdentifier: extID, ownIdentifiers: own))
    }

    @Test("来源是第三方进程（非集合成员）→ 不排除")
    func sourceIsThirdParty() {
        let own: Set<String> = [appID, extID]
        #expect(!ProcessOriginExclusion.shouldBypass(sourceIdentifier: "com.thirdparty.browser", ownIdentifiers: own))
    }

    // MARK: - 空 / nil 边界

    @Test("sourceIdentifier 为 nil → 不排除（拿不到来源身份就别乱直连）")
    func nilSource() {
        let own: Set<String> = [appID, extID]
        #expect(!ProcessOriginExclusion.shouldBypass(sourceIdentifier: nil, ownIdentifiers: own))
    }

    @Test("sourceIdentifier 为空字符串 → 不排除")
    func emptySource() {
        let own: Set<String> = [appID, extID]
        #expect(!ProcessOriginExclusion.shouldBypass(sourceIdentifier: "", ownIdentifiers: own))
    }

    @Test("ownIdentifiers 为空集合 → 永不排除（未配置自身身份就退化为无守卫）")
    func emptyOwnIdentifiers() {
        #expect(!ProcessOriginExclusion.shouldBypass(sourceIdentifier: appID, ownIdentifiers: []))
    }

    @Test("即便集合里意外混入空串，空来源仍不排除（守卫先于成员判定）")
    func emptySourceNeverMatchesEvenIfEmptyIsMember() {
        // ownIdentifiers 若被误配进 "" ，也不能让「拿不到身份（空来源）」的 flow 被直连。
        let own: Set<String> = [appID, ""]
        #expect(!ProcessOriginExclusion.shouldBypass(sourceIdentifier: "", ownIdentifiers: own))
    }

    // MARK: - 精确匹配（大小写敏感，决策钉死）

    @Test("大小写不同不算命中 —— 精确匹配，不做归一化")
    func caseSensitiveExactMatch() {
        // 决策（钉死）：签名标识按精确字节相等匹配，大小写不同即视为不同进程。
        // 调用方喂进来的两侧都是规范形态（我方已知的 bundle id + flow 的签名标识），
        // 无需在此做大小写归一化；若要改成不敏感，必须是一处测试可见的显式改动。
        let own: Set<String> = [appID]
        #expect(!ProcessOriginExclusion.shouldBypass(sourceIdentifier: "COM.EXAMPLE.PROXYAPP", ownIdentifiers: own))
    }

    @Test("前缀 / 子串不算命中 —— 必须整串相等")
    func noPrefixOrSubstringMatch() {
        let own: Set<String> = [appID]
        // extID 以 appID 为前缀，但它不是集合成员，不能因前缀关系被误命中。
        #expect(!ProcessOriginExclusion.shouldBypass(sourceIdentifier: extID, ownIdentifiers: own))
    }

    // MARK: - 便利构造器 ownIdentifiers(appBundleID:extensionBundleID:)

    @Test("构造器用两个不同 id 组出 2 元素集合")
    func builderProducesTwoElementSet() {
        let own = ProcessOriginExclusion.ownIdentifiers(appBundleID: appID, extensionBundleID: extID)
        #expect(own == [appID, extID])
        #expect(own.count == 2)
    }

    @Test("两个 id 相等时构造器去重为 1 元素集合")
    func builderDedupsEqualIDs() {
        let own = ProcessOriginExclusion.ownIdentifiers(appBundleID: appID, extensionBundleID: appID)
        #expect(own == [appID])
        #expect(own.count == 1)
    }

    // MARK: - 端到端：构造器产物驱动 shouldBypass（真实用法）

    @Test("构造器产物直接驱动判定：自身两个组件都 bypass，第三方不 bypass")
    func builderOutputDrivesShouldBypass() {
        let own = ProcessOriginExclusion.ownIdentifiers(appBundleID: appID, extensionBundleID: extID)
        #expect(ProcessOriginExclusion.shouldBypass(sourceIdentifier: appID, ownIdentifiers: own))
        #expect(ProcessOriginExclusion.shouldBypass(sourceIdentifier: extID, ownIdentifiers: own))
        #expect(!ProcessOriginExclusion.shouldBypass(sourceIdentifier: "com.thirdparty.browser", ownIdentifiers: own))
    }
}

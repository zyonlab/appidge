/// 纯、无状态的「按来源进程排除」判定：一条被捕获的 flow 若由「我们自己的组件」
/// （主 app 或系统扩展）发起，就必须强制直连（force `.direct`），别再代理它 —— 无论目的
/// 地址是什么。
///
/// 这是转发环（forwarding loop）硬化的第二道闸，和基于地址的 ``UpstreamExclusion`` **正交**：
/// - ``UpstreamExclusion`` 看**目的地**——目的地正是某台配置的上游代理才直连；
/// - 本判定看**来源身份**——发起方正是我方组件才直连。
///
/// 为什么需要两者并存：扩展把流量转发给上游时，那条「扩展→上游」的出站腿本身也会被系统重新
/// 捕获成新 flow。仅靠地址判定去拦它是脆弱的——一旦上游是非回环地址（如公司 `10.x` 代理）、
/// 或走域名 / 多网卡 / IPv4-mapped 等形态，地址匹配就可能漏掉，于是这条出站腿被再代理一次，
/// 自食其尾成环。按「来源进程身份」判定则与地址无关：只要发起方是我们自己，就一律直连，从根上
/// 断掉这类环。
///
/// 无状态、无 I/O（不解析 DNS、不查进程表），可从任意隔离域调用。匹配是**精确整串相等**
/// （大小写敏感、不做前缀/子串匹配），因为调用方喂进来的两侧都是规范形态：我方已知的
/// bundle id 集合，与 flow 的 `sourceAppSigningIdentifier`。
///
/// 接线（由协调者在扩展侧完成，不在此处）：`Extension/ProxyExtensionProvider.swift` 的
/// `effectiveRule` 里，在回环 / 上游排除之后、跑每进程规则表**之前**，用本条 flow 的
/// `flow.metaData.sourceAppSigningIdentifier` 与
/// `ProcessOriginExclusion.ownIdentifiers(appBundleID: APP_BUNDLE_ID, extensionBundleID: EXT_BUNDLE_ID)`
/// 调 ``shouldBypass(sourceIdentifier:ownIdentifiers:)``，命中即 `return .direct`。
public enum ProcessOriginExclusion {

    /// 这条 flow 是否由我们自己的组件发起、因而必须强制直连（bypass，别再代理它）。
    ///
    /// - Parameters:
    ///   - sourceIdentifier: 本条 flow 的来源签名标识（扩展侧即
    ///     `flow.metaData.sourceAppSigningIdentifier`）。`nil` 或空串 → 拿不到可信来源身份，
    ///     **不**排除（返回 `false`），把决策交回后续的地址判定 / 规则表，避免误把未知来源直连。
    ///   - ownIdentifiers: 我方自身组件的标识集合（一般是 `{APP_BUNDLE_ID, EXT_BUNDLE_ID}`，
    ///     见 ``ownIdentifiers(appBundleID:extensionBundleID:)``）。空集合 → 未配置自身身份，
    ///     退化为无守卫，返回 `false`。
    /// - Returns: 来源精确命中 `ownIdentifiers` 中某个成员时返回 `true`（应强制直连）；否则 `false`。
    public static func shouldBypass(sourceIdentifier: String?, ownIdentifiers: Set<String>) -> Bool {
        // 空 / nil 来源先挡掉：即便 ownIdentifiers 被误配进空串，也不能让「拿不到身份」的 flow 被直连。
        guard let sourceIdentifier, !sourceIdentifier.isEmpty else { return false }
        // 精确整串相等；ownIdentifiers 为空时 contains 自然返回 false。
        return ownIdentifiers.contains(sourceIdentifier)
    }

    /// 便利构造：把主 app 与系统扩展的 bundle id 组成一个 `ownIdentifiers` 集合。
    ///
    /// 用 `Set` 天然去重——两个 id 相等（配置异常）时得到 1 元素集合，不会重复计数。
    public static func ownIdentifiers(appBundleID: String, extensionBundleID: String) -> Set<String> {
        [appBundleID, extensionBundleID]
    }

    /// 来源可执行文件是否运行在**本 app bundle 目录内**（路径前缀匹配，带 `/` 边界，避免
    /// `/A.app` 误配到 `/A.appX/...`）。
    ///
    /// 为什么需要它：``shouldBypass`` 按签名标识 / 精确路径整串相等只覆盖了主 app 与扩展本体，
    /// 但 app bundle 内还有**辅助组件**——尤其 Sparkle 的 `Autoupdate` / `Updater.app` /
    /// `Downloader.xpc` / `Installer.xpc`，它们签名标识是 `org.sparkle-project.*`（不在
    /// ``ownIdentifiers``）、可执行文件也不是扩展本体那一个，于是它们发起的「取 appcast / 下载更新」
    /// 流量既不匹配标识、也不匹配精确路径，就被自己当普通进程代理了，走到抖动的代理路径上取更新失败。
    /// 用「凡落在本 app bundle 内的可执行文件都算我方」这一路正交信号兜住这类自更新流量：强制直连。
    ///
    /// - Parameters:
    ///   - sourcePath: flow 来源进程的可执行文件路径（扩展侧即 `ProcessPathResolver.executablePath`
    ///     从 audit token 解出的真实路径）。nil/空 → 拿不到路径，返回 `false`（不放行，交回后续判定）。
    ///   - bundlePrefix: 本 app bundle 根路径（形如 `/…/appidge.app`）。nil/空 → 未配置，返回 `false`。
    /// - Returns: `sourcePath` 以 `bundlePrefix` + `/` 为前缀时返回 `true`（应强制直连）；否则 `false`。
    public static func isWithinBundle(sourcePath: String?, bundlePrefix: String?) -> Bool {
        guard let sourcePath, !sourcePath.isEmpty,
              let bundlePrefix, !bundlePrefix.isEmpty else { return false }
        let root = bundlePrefix.hasSuffix("/") ? bundlePrefix : bundlePrefix + "/"
        return sourcePath.hasPrefix(root)
    }
}

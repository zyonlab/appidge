import Foundation

/// App↔扩展改走 XPC 的共享契约(取代 App Group UserDefaults + Darwin 通知——那条路径在
/// macOS System Extension 上不通:扩展以 root 身份跑,`UserDefaults(suiteName:)`/
/// `containerURL(forSecurityApplicationGroupIdentifier:)` 解析到 `/var/root/Library/Group
/// Containers/...`,App 以登录用户身份跑解析到 `~/Library/Group Containers/...`,两边永远读
/// 不到对方写的东西——Apple DTS 在开发者论坛确认过这是 sysex 的已知限制，官方推荐换 XPC。
///
/// **mach service 命名有个已经踩过坑、别再踩的规则**（见 git log `b92b35b`）：
/// `NEMachServiceName` 只要声明，值就**必须以扩展的某个 App Group 为前缀**，不能用
/// TeamID 前缀（`$(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)` 这种）——那条路径
/// 已经真机验证过会导致 `OSSystemExtensionError code 9`（network_extension 类别校验拒绝）。
/// 参照对象是这台机器上装的 Proxifier：它的 mach service 名字以它自己的 App Group
/// （`NXELXU5YLW.…`）开头。我们唯一的 App Group 是 `group.com.appidge`，所以
/// mach service 名字必须以 `group.com.appidge` 开头。
public enum XPCTransportConfig {
    /// **legacy** mach service 名字（扩展版本 ≤82 使用）。前缀是我们唯一的 App Group
    /// （满足上面那条硬规则）。
    ///
    /// 自扩展版本 83 起,真实名字是**版本化**的:`Extension/Info.plist` 的 `NEMachServiceName`
    /// 写成 `group.com.appidge.xpc.$(APPIDGE_EXT_BUILD_NUMBER)`(构建期展开)。为什么:
    /// 升级替换窗口里,旧扩展 job(含「等重启卸载」态)会一直占着老名字,新进程注册必然失败
    /// (2026-07-27 真机三连实锤,唯一出路是重启电脑);新旧版本各用各的名字,根本不抢。
    /// **名字的唯一真相源是 Info.plist**:扩展读自己的 plist 注册,app 读内嵌扩展的 plist
    /// 连接(经 ``connectionCandidates(preferred:)``),代码里不重复拼版本公式。
    public static let machServiceName = "group.com.appidge.xpc"

    /// mach service 名必须携带的 App Group 前缀(entitlement 硬规则,见类型注释)。
    static let requiredPrefix = "group.com.appidge"

    /// App 侧连接候选表:首选名(从内嵌扩展 plist 读出的版本化名)在前,legacy 兜底在后
    /// ——升级窗口里系统可能还在跑旧扩展(监听 legacy 名),回退保证仍然连得上。
    /// 首选名缺失/空白/不带 App Group 前缀(读坏)一律丢弃,fail safe 只剩 legacy;
    /// 与 legacy 相同则去重。恒非空、legacy 恒在末位。
    public static func connectionCandidates(preferred: String?) -> [String] {
        guard let preferred = preferred?.trimmingCharacters(in: .whitespacesAndNewlines),
              !preferred.isEmpty,
              preferred.hasPrefix(requiredPrefix),
              preferred != machServiceName
        else { return [machServiceName] }
        return [preferred, machServiceName]
    }
}

/// 扩展侧暴露给 App 的 XPC 接口：App → 扩展方向，一次一条已编码消息
/// （payload 是 `AppToExtensionMessage` 的 JSON 编码，具体编解码留给调用方——
/// EngineKit 的 transport 实现——这个协议本身不依赖 Core/EngineKit/AppFeature 的类型，
/// 只在 IPCContract 这个零依赖包里认 `Data`，`@objc` 是 XPC 的硬性要求）。
@objc public protocol ExtensionXPCProtocol {
    func send(_ data: Data)
}

/// App 侧暴露给扩展的 XPC 接口：扩展 → App 方向，对称地一次一条已编码消息
/// （payload 是 `ExtensionToAppMessage` 的 JSON 编码）。
@objc public protocol AppXPCProtocol {
    func send(_ data: Data)
}

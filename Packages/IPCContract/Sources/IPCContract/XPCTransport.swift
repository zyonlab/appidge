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
    /// 完整 mach service 名字，供 `Extension/Info.plist` 的 `NEMachServiceName`、
    /// 扩展侧 `NSXPCListener(machServiceName:)`、App 侧 `NSXPCConnection(machServiceName:)`
    /// 三处**原样一致**使用。前缀是我们唯一的 App Group（满足上面那条硬规则）。
    public static let machServiceName = "group.com.appidge.xpc"
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

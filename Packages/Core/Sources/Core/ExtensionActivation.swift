/// 系统扩展(NETransparentProxyProvider)的**安装/批准/运行状态**。这跟 `isEngineHealthy`
/// 是两回事:`isEngineHealthy` 是扩展*已经在跑*之后的运行时 fail-open 标志;这个枚举回答
/// 更前面的问题——扩展到底装没装上、用户批没批准、现在跑没跑。
///
/// 为什么需要它:没有这个信号,状态栏只能默认显示"引擎正常",哪怕扩展根本没装(比如缺
/// `system-extension.install` entitlement 时 `activate()` 直接失败)。那会让"为什么没拦截"
/// 无从判断。有了它,状态栏能如实说"扩展未安装 / 待批准 / 安装中",把人指向真正的卡点。
///
/// 属于运行时/瞬时状态,**不持久化**(和 `isEngineHealthy` 一样),每次启动由
/// `SystemExtensionActivator` 重新查询回填。
public enum ExtensionActivation: Sendable, Equatable, Codable {
    /// 还没提交激活请求,或查询结果未知(默认)。
    case inactive
    /// 激活请求已提交,正在进行(尚未得到批准/完成/失败的回调)。
    case activating
    /// 系统要求用户去「系统设置 → 隐私与安全性」点「允许」,还没点。
    case needsApproval
    /// 扩展已安装并在运行。
    case active
    /// **接管在跑，但跑的是旧版本**：升级后系统因旧扩展仍被占用而无法立即替换，
    /// `OSSystemExtensionRequest` 返回 `.willCompleteAfterReboot` —— 新版本要重启电脑后才生效。
    ///
    /// 必须与 `.active` 区分开：曾经两者都被报成 `.active`，等于谎报「新版本已接管」，
    /// 于是 app 照常起会话、会话绑到仍在跑的旧 provider，`runningExtensionVersion` 与
    /// `bundledExtensionVersion` 长期不一致且**无法靠重启隧道修复**
    /// （`restart()` 用的是版本无关的 providerBundleIdentifier，改不了系统注册哪个版本）。
    ///
    /// 此态下旧 provider 功能完整、仍在转发流量，故 ``isRunning`` 为真——停掉反而让用户断网。
    case activePendingReboot
    /// 扩展**已安装但被用户在「系统设置 → 通用 → 登录项与扩展」里停用**——不会收到任何 flow,
    /// XPC 也无人监听。区别于 `needsApproval`(从未批准):这是"批准过又被关掉",由启动时的
    /// `propertiesRequest` 状态查询发现(isEnabled == false 且不在等批准)。UI 据此把人指向
    /// 系统设置里重新打开,app 侧同时停止空耗(XPC 退避、不无脑重新激活)。
    case disabled
    /// 激活失败(如缺 entitlement、签名不符);`reason` 是系统给的原因,供 tooltip/日志。
    case failed(reason: String)

    /// 扩展是否确实在转发流量。`.active` 与 `.activePendingReboot` 都为真——后者跑的虽是旧版本，
    /// 但功能完整、流量确实在被接管，据此停接管只会让用户断网。版本是否陈旧由
    /// ``AppState/extensionNeedsRebind`` 单独回答，两件事不要混。
    public var isRunning: Bool { self == .active || self == .activePendingReboot }

    /// 新版本是否卡在「要重启电脑才生效」。UI 据此如实告知，自愈据此改走重新提交 activation
    /// （重启隧道对这一态无效）。
    public var isPendingReboot: Bool { self == .activePendingReboot }
}

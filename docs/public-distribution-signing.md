# 对外公开发包:苹果密钥/证书是否需要更换

本文件回答:Appidge **从内部/staging 测试转为对外公开分发**(官网直接下 DMG,非 App Store)时,
现有的苹果签名证书、公证流程、Network Extension 授权、Sparkle 更新公钥**要不要换**。

> **一句话结论:都不用换。**
> - **Developer ID Application 证书**:内部测试与公开分发**就是同一张**,Developer ID 天生为 App Store
>   之外的公开分发设计,不用为「上线」换证书。
> - **Sparkle EdDSA 公钥**:已是真实 `generate_keys` 产物,**不换**;私钥保管好即可。
> - **Network Extension 授权**:Appidge 的**透明代理**属于 **App Proxy / Transparent Proxy** 类,
>   自 2016 年起是**自助(self-serve)能力**,**无需向 Apple 申请特批 entitlement**。唯一需要向 Apple
>   申请的是 App Push Provider / Hotspot Helper——**与本产品无关**。
> - 平时唯一会「换」的场景:证书**吊销或过期后重新签新版**;但**已公证的旧包不受影响**(公证含时间戳)。

---

## 1. Developer ID 证书:测试与公开分发同一张

- **Developer ID Application** 证书就是 Apple 为「Mac App Store 之外分发」提供的签名身份。你之前跑通
  staging 归档用的那张,和公开发包用的**是同一张,不需要换**。不存在「测试证书」和「发布证书」之分。
- 前置条件仍然是:**Hardened Runtime 开启** + **Apple 公证(notarytool)** + **staple 票据**。你已跑通
  staging 归档说明这套已经成立,公开分发沿用即可。
- Gatekeeper 在用户机上放行的判据是:Developer ID 签名有效 + 已公证 + 已 staple。三者你已具备。

**依据**:Apple「Signing Mac Software with Developer ID」——Developer ID 证书用于 App Store 外分发,
仅账户 Holder 可创建;macOS 10.15+ 要求 Developer ID 软件既签名又公证方可默认放行。

---

## 2. 公开分发的硬性要求(你已满足,逐条核对)

| 要求 | 状态 | 说明 |
|------|------|------|
| Developer ID Application 签名 | 已有 | 与 staging 同一张证书 |
| Hardened Runtime | 需确认已开 | 公证前置条件;NE app 一般已开。核对 `codesign -d --entitlements` / build 设置 |
| 公证(notarytool) | 已跑通 | staging 归档已验证 |
| staple 票据到 DMG/app | 需确认 | 让离线机器也能校验;`xcrun stapler staple` |
| 容器 app 与系统扩展**都**签 NE entitlement | 已有 | 见第 3 节 |

> 公开分发相对内部测试**没有新增证书/密钥要求**,只是把「已签名 + 已公证 + 已 staple」的产物放到
> 官网下载。真正的差异在**分发渠道**,不在**签名材料**。

---

## 3. Network Extension(系统扩展)公开分发 —— 重点核实项

这是用户最担心的点(「NE 历史上要不要向 Apple 申请 entitlement」)。**核实结论:本产品不需要申请。**

### 3.1 哪些 NE Provider 需要向 Apple 申请,哪些自助

- **自助(self-serve,无需申请)**:自 2016 年 11 月起,**Packet Tunnel、App Proxy、Content Filter、
  DNS Proxy** 都是自助能力——在 Xcode 的 Signing & Capabilities 勾选、或在开发者网站给 App ID 打开
  「Network Extensions」capability 即可,**不需要向 Apple 发邮件申请**。macOS 11+ 的 **Transparent Proxy**
  (`NETransparentProxyProvider`,是 `NEAppProxyProvider` 的子类,走 app-proxy 授权)同属自助。
- **需 Apple 特批(managed)**:只有 **NE App Push Provider**(iOS 14+)和 **Hotspot Helper** 仍是受管
  capability,需通过开发者网站对应链接申请。**这两者与 Appidge 无关。**

**Appidge 是透明代理(全接管进程网络、按目的地判断)**,对应 **App Proxy / Transparent Proxy** 类,
落在**自助**区间——所以**不需要向 Apple 申请特批 entitlement**。请**不要**去走 App Push /
Hotspot Helper 的申请流程。

### 3.2 Developer ID 分发下的 NE 打包要求(操作层,你已在做)

- App Store 外分发**必须**把 NE 打成 **System Extension(sysex)**,不能用 App Extension(appex)——
  appex-based NE 与 macOS 多用户/无人登录执行模型不契合,Apple 明确 Developer ID 走 sysex。你的工程
  已经是系统扩展,符合。
- 系统扩展签名时 entitlement key 用 **`-systemextension` 后缀**变体;**容器 app 与系统扩展两侧都要签**
  `com.apple.developer.networking.networkextension`。这些是你现有工程已具备的,公开分发不变。
- 系统扩展同样要**公证**(随 app bundle 一起提交 notarytool 即可,无额外单独流程)。

**依据**:Apple TN3134「Network Extension provider deployment」(2025-08 更新)与开发者论坛
Apple 工程师(eskimo/Quinn)答复:自助 vs. managed provider 的划分、Developer ID 必须用 sysex、
`-systemextension` 签名后缀。

---

## 4. Sparkle EdDSA 更新签名:不换

- Sparkle 用 **EdDSA(ed25519)** 对每个更新包签名,app 内嵌**公钥**(`SUPublicEDKey`)校验。你的公钥
  已是真实 `generate_keys` 产物,**公开分发不需要换**。
- **私钥**留在 Keychain / 受保护 CI secret,**绝不进 git**。只要私钥不泄露、不轮换,公钥就一直有效。
- Sparkle 的 EdDSA 签名与 Apple 的 Developer ID/公证是**两套独立机制**:前者保更新链路完整性,后者
  保 Gatekeeper 放行。两者都已就绪,互不影响。

---

## 5. 证书有效期 / 续期:澄清「密钥到底要不要换」

用户的真实关切是「密钥要不要换」。精确回答:

- **平时不用换。** Developer ID 证书有有效期(签发起约数年),但**公证时会打时间戳**:一个包只要在
  证书有效期内完成签名 + 公证,**即便日后证书自然过期,这个已公证的旧包仍然能在用户机上正常放行**。
  用户已装的版本不会因证书过期而失效。
- **需要换的唯二情形**:
  1. 证书被 **Apple 吊销(revoke)**(极少见,通常因安全事件)——此时需重新申请证书并重签**新版本**;
     但**旧的已公证包**是否受影响取决于吊销原因(常规过期不吊销,不影响旧包)。
  2. 证书**过期后要发新版本**——为**新构建**续/换一张 Developer ID 证书重新签名公证即可,**老包不动**。
- 也就是说:**「公开发包」这个动作本身不触发任何换证书/换密钥**;只有「证书生命周期到期且要出新版」才
  需要续新证书,且**只作用于未来的新构建**。

---

## 6. 待人工确认 / 潜在闸门清单

| 项 | 结论 | 需人工做的事 |
|----|------|-------------|
| Developer ID Application 证书 | **不换**,测试=公开同一张 | 无(确认未过期即可) |
| Hardened Runtime | 应已开 | 核对 build 设置确已启用(公证前置) |
| 公证 + staple | 已跑通归档 | 发布前确认 DMG/app 已 staple |
| NE entitlement(透明代理) | **无需向 Apple 申请**(App Proxy 自助) | 无。**切勿误走 App Push 申请流程** |
| 系统扩展打包/签名(sysex + `-systemextension`) | 已符合 | 沿用现有工程 |
| Sparkle EdDSA 公钥 | **不换** | 无。仅确保私钥安全、不进 git |
| 证书续期 | 仅到期出新版时 | 到期前续新证书,仅影响新构建,旧包不受影响 |

> **唯一理论上的「向 Apple 申请」闸门**只会在 provider 类型是 App Push / Hotspot Helper 时出现——
> Appidge 不属于,故**没有需要向 Apple 申请的 entitlement 闸门**。

---

## 参考出处

- Signing Mac Software with Developer ID(Developer ID = App Store 外分发身份):
  <https://developer.apple.com/developer-id/>
- Distribute outside the Mac App Store(macOS,Xcode 帮助):
  <https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html>
- TN3134: Network Extension provider deployment(sysex vs appex、Developer ID 打包、provider 类型):
  <https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment>
- Apple 论坛(eskimo/Quinn):Packet Tunnel/App Proxy/Content Filter/DNS Proxy 自 2016-11 起自助,
  仅 App Push Provider 与 Hotspot Helper 为受管需申请;Developer ID 必须用 System Extension:
  <https://developer.apple.com/forums/thread/735356> ·
  <https://developer.apple.com/forums/thread/797007> ·
  <https://developer.apple.com/forums/thread/67613>
- Network Extensions Entitlement 文档:
  <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension>
- 公开分发需签名 + 公证(Gatekeeper,macOS 10.15+):
  <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>

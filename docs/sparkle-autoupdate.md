# Sparkle 自动升级 · 集成说明与剩余人工步骤

本文件说明 appidge 里 Sparkle 2.x 自动升级的**代码层集成**已做了什么,以及发布前
**必须由人补齐**的步骤(appcast 托管、EdDSA 密钥、发布签名)。代码层不含任何服务器托管或私钥。

## 已完成(代码层)

- **SPM 远程包**:`https://github.com/sparkle-project/Sparkle`,`upToNextMajorVersion` from `2.0.0`
  (首次解析锁到 **2.9.4**,见 `appidge.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`)。
  只加到 **App** target(扩展不参与升级 UI)。
- **Updater 接入**:`App/AppidgeApp.swift` 持有 `SPUStandardUpdaterController(startingUpdater: true, …)`——
  一构造即启动后台自动检查。菜单栏下拉「**检查更新…**」(`App/ContentView.swift` 的 `MenuBarView`)
  调用 `updater.checkForUpdates()` 手动触发一次检查。
- **Info.plist**(`App/Info.plist`):
  - `SUFeedURL` = `https://appidge.app/appcast.xml`(**占位**,发布前替换,见下)。
  - `SUPublicEDKey` = `TODO-REPLACE-WITH-ED-PUBLIC-KEY`(**占位**,发布前替换成真实 base64 公钥)。
  - `SUEnableAutomaticChecks` = `true`。
- app 非沙盒(Developer ID 分发),用 Sparkle 标准配置,无需 XPC 服务分离 / 额外 sandbox 桥接。

## 剩余人工步骤

### 1. 生成 EdDSA(ed25519)密钥对 —— 只做一次

Sparkle 用 EdDSA 对每个更新包签名,app 内嵌**公钥**验证。私钥**绝不进 git**。

Sparkle 的 `generate_keys` 工具在解析后的包产物里(SPM 缓存 / Xcode DerivedData 的
`Sparkle` artifact 的 `bin/` 下),或从 https://github.com/sparkle-project/Sparkle/releases
下载官方 `Sparkle-2.x.tar.xz` 里的 `bin/generate_keys`。

```sh
./bin/generate_keys
```

- 首次运行会把**私钥存进当前用户的 macOS 登录钥匙串**(item 名 `Private key for signing Sparkle updates`),
  并在终端打印**公钥**(base64)。
- 把打印出的公钥填进 `App/Info.plist` 的 `SUPublicEDKey`。
- **私钥存哪**:就留在生成它的那台机器的**登录钥匙串**里(默认行为),不要导出到仓库、不要贴进任何文件。
  若要在 CI / 换机上签名,用 `generate_keys -x private_key_file` 导出到一个**仓库外**的安全文件
  (如密码管理器 / CI secret),用 `sign_update --ed-key-file` 引用;导出的文件一律不进 git。

### 2. 每次发布用 `sign_update` 签名

对每个要发布的 `appidge-<version>.zip`(或 `.dmg`):

```sh
./bin/sign_update appidge-<version>.zip
# 输出形如:sparkle:edSignature="…" length="…"
```

把输出的 `sparkle:edSignature` 与 `length` 填进 appcast 里该版本 `<enclosure>` 的属性。
签名用的私钥自动从钥匙串取(见上)。

### 3. 托管 appcast.xml

- 在 `SUFeedURL` 指向的地址(现占位 `https://appidge.app/appcast.xml`)托管一个 `appcast.xml`(RSS)。
  发布前把这个 URL 换成你真实的托管地址(HTTPS)。
- 每次发版追加一个 `<item>`:`<sparkle:version>`(= `CFBundleVersion`)、
  `<sparkle:shortVersionString>`、`<enclosure url=... sparkle:edSignature=... length=...>`。
- 更新包(zip/dmg)本身也托管在可 HTTPS 下载的地址,URL 写进 `<enclosure url>`。
- 可用 Sparkle 自带的 `generate_appcast` 工具:指向一个放着所有已签名更新包的目录,自动产出/更新 appcast。

## ⚠️ 系统扩展升级后的会话重绑(已处理,无需为 Sparkle 额外做)

透明代理是**系统扩展**。升级换包时有个已知坑:app 起的透明代理会话可能还**绑在旧 provider**上,
新 provider 接管、旧的终止后,会话绑在死掉的旧 provider = 全系统流量黑洞。

这条已由 app 侧的**版本握手重绑**修复:
- `App/AppidgeApp.swift` 的 `maybeHealStaleBinding()`:扩展经 XPC 回报当前 active provider 版本,
  与包内嵌扩展版本比对;升级窗口内先不重绑,待新 provider 确认接管(版本匹配)再**重绑一次**会话。
- 底层重绑走 `App/TransparentProxyController.swift`(`restart()` / `reset()`)。

Sparkle 换包后会**退出并重启 app**,重启走的就是同一条启动 → 激活扩展 → 版本握手重绑的升级路径,
因此 **Sparkle 自动升级不需要为此做任何额外处理**——它复用既有的升级自愈逻辑。

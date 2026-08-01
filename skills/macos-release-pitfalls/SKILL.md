---
name: macos-release-pitfalls
description: macOS 应用签名、公证、出包与 Sparkle 自动更新的实战经验（来自真实商业产品的完整发布周期）。凡是涉及 macOS app 的 codesign/notarytool/staple/DMG 出包、XcodeGen 工程管理、Developer ID 分发、Sparkle appcast 自动更新、系统扩展打包、build 号管理，或排查「公证失败/时间戳失败/staple 失败/更新收不到」类问题时，务必先读本 skill——这些坑几乎每个都要浪费半天才能自己撞明白。
---

# macOS 发布链路实战经验

以下每条都来自真实产品的踩坑记录，按开发→构建→发布顺序组织。

## 工程管理（XcodeGen）

- 用 XcodeGen 时 **project.yml 是唯一真相源**：手工改 pbxproj 的任何东西（尤其 Swift Package
  引用，如 Sparkle）都会被下一次 `xcodegen generate` 冲掉。所有包引用、build setting、
  文件组织都写进 project.yml。
- 新增 .swift 文件后必须 `xcodegen generate` 并提交 pbxproj，否则报 "cannot find in scope"
  ——工程用显式文件引用时，磁盘上的文件不等于参与编译的文件。
- `xcodebuild -resolvePackageDependencies` 在工程无远程包时会**删掉** Package.resolved。
- 签名身份走 `.env` → 脚本生成 git-ignored xcconfig → project.yml 只写 `$(DEVELOPMENT_TEAM)`
  间接量。收益是模板化复用（Team ID/Bundle ID 是公开标识，保密不是目的）。
- xcconfig 的 `//` 是行注释，URL 要写成 `https:/$()/example.com` 用空展开隔断双斜杠。
- SwiftLint strict 的 file_length/type_body_length 预算要提前规划：热文件（App 入口、大
  reducer）顶到上限后，「必须改这个文件」和「拆文件要动工程」会同时变贵。
- Swift 6 严格并发从第一天开、零 warning 当闸门；事后补隔离的成本远高于随写随修。

## 签名与公证

- 发布链路固定成一条 fail-fast 脚本流水线：archive → notarize → staple → DMG → （appcast
  签名 →）校验 → 上传。
- 归档前 `rm -rf build/*.xcarchive build/export`——残留会静默导出旧版本。
- 公证失败**先重试再排查**：网络瞬断是最常见原因，重跑 `notarytool submit` 即可，不用重新
  归档。staple 首次失败常是 Apple 票据同步延迟，重跑就好。分发 zip 必须在 staple 之后打。
- **系统扩展没有免公证的测试捷径**：sysextd 直接拒载未公证包（error 8, code signature
  invalid）。含系统扩展的产品，真机迭代节奏必须按「串行出包」设计。
- codesign 的**安全时间戳**是隐蔽故障源：时间戳事务由系统常驻服务 `XPCTimeStampingService`
  发出，它无视系统代理例外名单、持有跨天的 keep-alive 连接池。本机代理环境不干净时
  archive 会以 ~50% 概率报 "A timestamp was expected but was not found"。出包窗口的操作解：
  关系统 HTTP/SOCKS 代理 → `pkill -9 -x XPCTimeStampingService` → 用真实 `codesign
  --timestamp` 探针连测 3 次绿再 archive（curl 探测不可靠）。
- TCC「App 管理」会拦 rsync 写 /Applications 内的 bundle；把旧 bundle 整体 mv 走再 ditto
  新副本可行。
- 公证上传走不稳定代理可能在上传阶段无限卡死（无 submission id）——直连上传更稳。

## 版本号纪律

- **build 号是全渠道（staging/production）共用的一条单调递增序列**。出包工具应拉取所有线上
  feed 求历史最高值并强制新包严格更高——「用户装到的 build 比线上还高、从此收不到更新」是
  静默死状态。
- 首发时 feed 还不存在会形成校验死锁：用一次性的显式环境变量开关放行，绝不改成静默跳过。
- 发错的包只能发**更高** build 修复，永远不能降号回滚。每次发布记录产物 SHA-256 备审计。

## Sparkle 自动更新

- Sparkle 2 用 `SPUStandardUpdaterController`，只链接 App target；扩展/helper 绝不链 Sparkle。
- EdDSA 私钥留 Keychain / CI secret；appcast 用官方 `generate_appcast` 生成，不手拼 XML。
- feed URL 经 xcconfig 按环境注入，换更新域名零代码改动。
- 对象存储用不可变版本路径，`appcast.xml` 最后原子更新——feed 绝不能指向未上传完的文件。
- 如果 app 本身是代理/防火墙类产品：Sparkle 的 Autoupdate/Updater/Downloader.xpc 签名标识是
  `org.sparkle-project.*`（不是你的），会被自家流量规则误伤——放行逻辑要按「可执行文件在本
  app bundle 内」判定，不能只按签名标识。

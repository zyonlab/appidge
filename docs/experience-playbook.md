# Appidge 开发经验手册（可迁移版）

> 从 appidge（macOS 按进程透明代理 + Creem 商业化 + Cloudflare 免费层双环境）的完整开发周期中
> 提炼，供下一个 macOS 应用 / 网络转发产品 / MoR 支付接入 / Cloudflare 免费方案复用。
> 每条都来自真实踩坑或真机实测，不是理论。整理于 2026-08-01。

---

## 一、macOS 应用：工程、构建与发布

### 工程结构

- **XcodeGen（project.yml）当工程唯一真相源**。手工改 pbxproj 的任何东西（尤其 Swift Package
  引用）都会被下一次 `xcodegen generate` 冲掉——Sparkle 引用必须声明在 project.yml 里。
  新增 .swift 文件后必须重新 generate 并提交 pbxproj，否则「cannot find in scope」。
- **签名身份走 .env → 生成 xcconfig 的间接链**：project.yml 里只写 `$(DEVELOPMENT_TEAM)`
  之类的间接量，真值在 git-ignored 的生成文件里。Team ID/Bundle ID 本质是公开标识（随分发
  产物可见），这样做的收益是模板化复用 + 换身份不动工程，而不是保密。
- **xcconfig 的坑**：`//` 在 xcconfig 里是行注释，URL 里的双斜杠要写成 `https:/$()/example.com`
  用空展开隔断。
- **SwiftLint strict 的预算要提前规划**：file_length=400 / type_body_length=250 顶到上限后，
  在「必须改这个文件」和「新文件要动 pbxproj」之间会很难受。热文件（App 入口、大 reducer）
  从一开始就按拆分设计。
- Swift 6 严格并发从第一天开启，零 warning 当闸门。事后补并发隔离的成本远高于随写随修。

### 签名、公证、出包

- **发布链路固定为一条脚本化流水线**：archive → notarize → staple → DMG → appcast 签名 →
  校验 → 上传，任一步失败即停。归档前 `rm -rf build/*.xcarchive build/export`——残留会导出旧版本。
- **公证失败先重试再排查**：网络瞬断是最常见原因，重跑 `notarytool submit` 即可，不用重新归档。
  staple 首次偶发失败是 Apple 票据同步延迟，重跑就好。分发 zip 必须在 staple 之后打。
- **系统扩展没有「未公证的测试捷径」**：sysextd 拒载未公证包（error 8 code signature invalid）。
  真机换扩展只能走完整公证链，这决定了迭代节奏必须「串行出包」：一次修一批、一次出一包。
- **TCC「App 管理」会拦 rsync 写 /Applications 内的 bundle**；整个 mv 走再 ditto 新副本可行。
- **build 号是全渠道共用的单调序列**：staging/production 共用一条递增线，出包工具应拉取全部
  线上 feed 求历史最高值并强制新包严格更高——「用户装到的版本比线上新版本号还高、从此收不到
  更新」是静默的死状态。首发 feed 不存在的死锁用一次性显式开关放行，绝不改成静默跳过。

### Sparkle 自动更新

- 用 Sparkle 2 `SPUStandardUpdaterController`，只链接 App target，扩展绝不链 Sparkle。
- EdDSA 私钥留 Keychain / CI secret，公钥进 Info.plist；appcast 用官方 `generate_appcast`
  生成，不手拼 XML。
- feed URL 走 xcconfig 注入（每环境一个值），换更新域名不用改代码。
- 对象存储用不可变版本路径，`appcast.xml` 最后原子更新——feed 绝不能指向尚未上传完的文件。
- 每次发布记录 appcast/DMG 的 SHA-256（release manifest），错误包只能发更高 build 修复，
  永远不能靠降号回滚。

---

## 二、网络转发应用（Network Extension 透明代理）的坑

### 架构层决策（做对了后面全省）

- **NETransparentProxyProvider（socket 层 flow）优于 TUN（包层）**，如果产品是按进程分流：
  进程签名/PID 是系统在连接建立前给的元数据，归因精确；TUN 只能事后反查连接表，短连接/UDP
  经常失败且静默。TUN 系产品的 fake-ip、路由劫持、崩溃断网，这套架构天然没有。
- **fail-open 是底线**：扩展死了流量按原路走，最坏是「没分流」不是「没网」。授权服务故障、
  引擎异常都不能变成系统级断网。
- **回环流量到不了 transparent proxy provider**（平台行为，实测 0 命中），防御性代码可以留,
  但别把功能设计建立在拦截 loopback 上。
- **数据面热路径禁止 per-chunk I/O**；UI 常驻动画（symbolEffect `.repeat(.continuous)`）在
  ProMotion 屏上会吃满一个核。

### 防环与自我排除（转发类产品的命门）

- **本地代理（用户的 Clash/xray）是全系统流量的汇聚点，绝不能接管，只能观测**。「接管+直连」
  = 全系统代理吞吐在你的扩展里二次读写——同根因事故连出三次才形成铁律。
- **排除信号要三路**：签名标识 + 可执行路径 + 「是否在本 app bundle 内」。未签名 CLI 的标识
  统一报 `a.out`，按标识排除会连坐所有未签名程序，必须回退到路径。Sparkle 的
  Autoupdate/XPC 辅助进程签名是 `org.sparkle-project.*`，不在你的标识清单里——自更新被
  自己的代理拦死就是这么来的。
- **本地代理身份要周期性重发现**，不能只在配置变更时查一次：用户换代理软件（xray → mihomo）
  不会改你这边的 127.0.0.1:7890 配置，监听者却换人了。
- **Apple 签名基础设施必须硬直连、先于用户规则**：codesign 时间戳/OCSP/公证域名走了抖动代理
  会让 archive 半数失败。且时间戳 flow 有时只带 IP 不带域名（Apple 自有 17/8 段），
  纯域名匹配会穿闸——要补 IP 段闸。另外系统的 `XPCTimeStampingService` 无视代理例外名单、
  有跨天的 keep-alive 连接池，出包窗口要关系统代理 + `pkill -9` 它。

### 系统扩展升级（最深的坑，三种病）

macOS 按 (short, build) 元组决定是否替换系统扩展，替换窗口就是竞态窗口：

1. **会话绑死旧 provider（黑洞断网）**：会话绑在已终止的旧 provider 上，拦流量却转发不了。
   修法是状态机：「运行≠包内」只记标志不动作；「变回匹配」才重绑一次；持续不匹配 8s 后做
   一次有界重启破死锁。「启动时无条件 restart」会绑得更早、黑洞更严重——不是解法。
2. **XPC 监听器注册竞态**：换血窗口里新进程的 `NSXPCListener` 静默注册失败（API 无错误回调），
   旧 job「等重启卸载」态还占着固定 mach 名。根治 = **mach 服务名带扩展版本号**（新旧进程
   名字空间隔离）+ 进程内自探活、sessionless 才 exit 重生 + app 侧候选名轮换。
3. **替换请求悬挂**：新 app 启动只探状态、`activate()` 被异步条件（试用相位）门住而从未提交
   → 系统永不替换旧扩展。教训：**激活请求要幂等提交、门槛条件越少越好**，所有「重启接管」
   入口都顺带补一次 activate。

根本缓解：**扩展版本与 app build 解耦**——扩展内容没变就不 bump 扩展版本，系统跳过替换，
竞态窗口根本不打开。配出包闸门双向硬失败（改了没 bump / 没改乱 bump）。

密集测试出包会积累「waiting to uninstall on reboot」的扩展坟场，只有重启电脑能清。
验证升级用 `curl -m3` 逐秒探网 + 看连接日志有 flow，别只看 UI。

### 与 TUN 系软件共存（真实用户环境）

- 用户大概率装着 Clash 系客户端且开着 TUN。**两个全接管层叠加 = 抢流量 + DNS 被截进对方
  虚拟网卡 = 断网**，而用户会归咎于最后安装的软件（你）。
- 对策三层：产品内探测 `utun*` 网卡并在接管开启时警示；官网下载区放显眼的警示文案；FAQ
  第一条就回答「能不能同时开 TUN」。话术要点：关 TUN 不影响节点/订阅，只保留本地端口当上游。
- 排障时先分清「谁在接管」：app 退出≠扩展没在拦（查进程 + log stream 看 flow 日志）；
  Clash 侧的断网也可能是它自己的 DNS 配置残缺（机场订阅普遍缺 `dns.enable`/`dns-hijack`，
  规则模式靠 CN 直连兜住、全局模式就断网）——别急着背锅，用对照实验归因。

---

## 三、Creem（MoR 支付）接入：API 到运营

### API 与 webhook 的实测结论（文档没写全的部分）

- **一切以 test 模式实测为准，不按文档猜字段**。fixtures 必须来自真实捕获的脱敏 payload；
  test 模式（`test-api.creem.io`）与生产完全隔离、key 独立。
- **验签是 Creem 自己的方案**：`creem-signature` = hex(HMAC-SHA256(secret, 原始请求字节))，
  恒定时间比较，secret 按 Dashboard 字面值用（`whsec_` 前缀不剥离、不 base64 解码）。
  没有 `webhook-id`/`webhook-timestamp` 头 → 无漂移窗口可校验，防重放只能靠 payload 顶层
  事件 ID 的数据库唯一约束幂等。
- **webhook 与 license 之间没有公共 join key**：三种关键事件（checkout.completed /
  refund.created / dispute.created）都不带 license key，license API 又查不到 order——
  **无法用 webhook 精确吊销 license**。webhook 只做验签+幂等落库审计+order tombstone。
- **吊销主路 = 客户端每日 validate**：Dashboard 手动 disable license → 上游 status=disabled →
  facade 映射 revoked → App 锁定。**退款/拒付不会自动 disable license**（实测），运营 SOP
  必须包含「处理退款的同时手动 disable」，漏做 = 退款后用户继续用。
- **本地 deny 优先于上游 active**：D1 里标 revoked 就直接返回 revoked，这是运营的最后杠杆。
- facade 设计：客户端绝不直连持密上游；错误模型收敛成固定枚举（invalid_license /
  activation_limit / expired / revoked / rate_limited / upstream_unavailable...）；未知/缺失
  状态一律按 transient 进离线宽限，绝不误翻成 revoked。

### 审核/风控/运营侧

- MoR 账户是生死线，**拒付率 <1% 是硬红线**（一笔 $9.99 的拒付实际损失约 3.5 倍售价 +
  计入比率）。头号策略是把退款做得足够顺畅：退款入口在官网 footer/定价页/独立退款政策页
  三处可见，14 天无理由，邮件即可。
- **账单描述符（statement descriptor）要含品牌名**——用户看到陌生扣款名会直接当盗刷去拒付。
- 客户端要有**离线宽限 + 授权缓存**（默认 7 天）：支付商/自建 facade 任何一方临时不可用都
  不能立即锁死付费用户。license key/instance id 存 Keychain 不落明文。
- UI 文案不写死支付商名字——换 MoR 时不用改客户端和译文（本项目经历了 Creem→Polar→Creem
  的反复，env 变量名里还留着 `POLAR` 的化石）。教训：**改支付商叙事时，把所有涉及文档一次
  性加时效横幅纠偏**，否则半年后没人分得清哪个方向是现实。

---

## 四、Cloudflare 免费层：双环境商业化方案

### 拓扑与原则

- 免费层可以跑完整的商业化闭环：6 个 Worker（web/api/updates × staging/production）+
  2 个 D1。官网和更新包都用 Workers 静态资源托管，**单文件 25MiB 上限**——DMG 超限才迁 R2
  （域名从第一天就定死 `updates.<domain>`，迁移时客户端零改动）。
- **免费层是成本目标，不是可靠性假设**：客户端必须有离线宽限，Worker 挂了不能锁死用户。
- 环境不是「创建」出来的，是 wrangler 配置里**声明**出来的（`[env.staging]`/`[env.production]`
  + custom domain），首次 `wrangler deploy --env` 自动落地 Worker 和域名证书。唯一要手动建的
  是 D1（`wrangler d1 create`），运维 CLI 刻意不代建（fail-closed，只打印命令）。
- secret 只走 `wrangler secret put`（本地 `.dev.vars` git-ignored）；公开配置进可提交的
  per-env conf 文件，形成「已提交的都是公开值」的清晰分层。

### 运维 CLI 的设计模式（appidge-ops，值得照抄）

- **单一入口 + 显式环境参数**：`ops-cli <command> <staging|production>`；配置矩阵是
  几个纯 shell conf 文件，无框架。
- **默认 dry-run，`--apply` 才写**；production 三重保护（`--apply` + `--confirm-production` +
  环境变量审批），缺一 fail-closed。
- `preflight` 分本地/远端两档，远端只读（查 secret 名不读值、查 D1 存在、查 migrations
  pending）；`plan` 打印完整计划不动任何东西。
- D1 **不做 down migration**，只前滚补偿 migration；production migration 前记 Time Travel
  bookmark（免费层窗口 7 天）。
- 部署后断言产物（静态站里真的包含 checkout/download 链接）+ healthz smoke + 失败提示
  `wrangler rollback`。

---

## 五、跨领域的流程经验

- **渐进式 monorepo**：Swift 工程原地不动（路径、签名、扩展 embed 都脆），旁边长出
  pnpm workspace（apps/web、apps/api）。工具选 pnpm+Turborepo 够用就好，不上 Bazel/Nx。
- **OpenAPI 当跨语言契约 + 脱敏 fixtures 做契约测试**，初期不上跨语言代码生成（脆、维护贵）。
- **TDD 的实际执行线**：Core reducer / Worker webhook 这类纯逻辑必须先失败测试；bug 修复
  先写复现测试；mock 只打在协议边界。真机才能复现的（升级竞态）用「验证清单 + 下次出包实测」
  管理，诚实标注「未真机验证」。
- **证据型状态文档**：每个勾选背后是可复现命令+输出，「代码完成 ≠ 上线完成」，缺真实凭证的
  项保持未勾选并写最短解锁步骤。文档过期时**加时效更正横幅，不重写历史正文**——历史证据的
  价值恰恰在于它没被篡改。
- **并行 agent/协作者按目录切文件所有权**，集成按依赖顺序逐个 rebase+测试，不一把梭合并。
- **用户反馈的归因纪律**：「装了你的软件后断网」≠ 你的锅——先建对照实验（关掉你的产品还断吗）,
  再查环境（对方 TUN、DNS 配置、节点状态）。反过来，能被用户环境搞坏的点（TUN 冲突）要
  提前做产品内警示，把锅在发生前甩清楚。

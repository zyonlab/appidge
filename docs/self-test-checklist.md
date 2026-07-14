# appidge 真机自测清单

> 这份清单把所有**只能人工 / 只能真机**验证的点收在一处。它们不是没做，而是 loop 物理上做不了：
> 需要（a）人在系统设置点「允许」、（b）真实网络 + 真实上游代理、（c）Apple 签名/公证凭据。
> 代码侧全部已实现并本地验证（`swift test` 五包 + `swiftlint --strict` + `xcodebuild` 零并发警告）。
>
> 用法：从 §0 前置开始，逐条做完把 `[ ]` 勾成 `[x]`，卡住的写在该条下面。§9 是等你回填的开放问题。

---

## 0. 前置（一次性，不做后面全跑不了）

- [ ] **0.1 Apple Developer Portal 开 System Extension capability（你来，约 5 分钟）**
  - 现状（2026-07 实测确认）：`PROFILE_APP` 指向的 Developer ID profile 授权了完整
    NetworkExtension，但**没有** System Extension capability。一旦给 `App.entitlements` 加
    `com.apple.developer.system-extension.install`，`xcodebuild` 就拒签，报：
    > Provisioning profile "appidge App DevID" doesn't support the System Extension capability.
    这个 entitlement **没有**对应的 App ID 主 capability，藏在 **Additional Capabilities** 里，必须开了它、
    重签 profile 才行——不是随便就能签的。
  - 步骤：登录 [developer.apple.com](https://developer.apple.com) → Certificates, IDs & Profiles
    → Identifiers → 选 `APP_BUNDLE_ID`(com.appidge.app) → 切到 **Additional Capabilities** 标签页
    → 勾 **System Extension** → Save → Profiles 里把 `appidge App DevID`（Developer ID 型）Edit/重生成
    → 下载的 `.provisionprofile` 覆盖 `PROFILE_APP` 指向的文件。
  - **只有主 app 的 profile 要动**：扩展（`PROFILE_EXT`）只需 Network Extension，不涉及 System Extension。
  - 期望：改回 entitlement 后 `xcodebuild -scheme App -configuration Release` 能签过。

- [ ] **0.2 装 app + 让扩展能被加载 + 点「允许」**
  - **加载前提（Developer ID 的系统扩展二选一）**：macOS 只会加载①**已公证**的，或②**开发者模式**下的
    系统扩展。
    - 公证（推荐，和 Proxifier 同路，不用动 SIP）：跑 `scripts/` 里的打包+公证（`notarytool` 需要
      Apple ID app 专用密码 / API key，配 `.env`，明文不经手）→ staple → 装 `/Applications`。
    - 开发者模式（快但要关 SIP）：Recovery 里 `csrutil disable` → `systemextensionsctl developer on`
      → 装未公证 build。多数人不愿关 SIP，仅本地调试用。
  - 批准位置（**macOS 15+/26 已挪窝**，实测确认）：启动 app 触发 `OSSystemExtensionManager.submitRequest`
    → **系统设置 → 通用 → 登录项与扩展 → 网络扩展** → 打开 appidge 那条（旧文档写的「隐私与安全性」已过时）。
  - 期望：`systemextensionsctl list` 里 `EXT_BUNDLE_ID` 处于 `[activated enabled]`；app 状态栏从
    「扩展未安装 / 待批准」变「引擎正常」。

- [ ] **0.3 跑 smoke 脚本**
  - 步骤：`./scripts/smoke-ne.sh`（会签名校验 → 启动 app → 提交扩展激活 → 发一条 curl 走代理 → 抓
    `log stream`）。
  - 期望：脚本打印出观测到的进程身份级别（见 §9.1 回填）。

---

## 1. 基础代理转发（P0/P1，「代理」名副其实）

- [ ] **1.1 SOCKS5 上游真的走通**
  - 准备：`代理服务器` 页加一台真实 SOCKS5 上游（本地起一个，或 `ssh -D 1080` / Shadowsocks / Clash）。
  - 步骤：把某个 app（如某个命令行工具或浏览器）在 `规则` 页设成「代理」→ 用它访问一个能回显出口 IP 的
    服务（如 `curl ifconfig.me`）。
  - 期望：出口 IP 是**上游代理的 IP**，不是本机公网 IP。设成「直连」时是本机 IP。

- [ ] **1.2 HTTP CONNECT 上游走通**
  - 同 1.1，但上游换成 HTTP CONNECT 代理（`代理服务器` 页协议选 HTTP CONNECT）。
  - 期望：HTTPS 流量经 CONNECT 隧道走通，出口 IP = 上游。

- [ ] **1.3 SOCKS5 用户名/密码认证**
  - 准备：一台要求 user/pass 认证的 SOCKS5 上游，凭据填进 `代理服务器` 表单。
  - 期望：认证通过、能连；故意填错密码时连不上（连接日志里该连接 failed）。

- [ ] **1.4 DNS-over-proxy（防 DNS 泄漏）**
  - 准备：一台代理 + 本地抓 DNS（如 `tcpdump -i any port 53` 或 Wireshark）。
  - 步骤：让一个 proxied 的 app **用域名**（不是 IP）访问某站点。
  - 期望：本地**看不到**该域名的明文 DNS 查询（域名交给代理端解析）。已知限制：app 直接用 IP 连时仍本地解析。

---

## 2. 规则（细粒度 + 拦截 + 右键指定）

- [ ] **2.1 进程 × 主机 × 端口 细粒度规则**
  - 步骤：`规则表` 页加一条，比如 `进程=* 主机=*.google.com 端口=空 → 代理`；其它直连。
  - 期望：该进程访问 `*.google.com` 走代理、访问别处直连（连接日志逐条核对 rule 列）。

- [ ] **2.2 规则从上到下、首个命中**
  - 步骤：加两条会同时命中的规则、拖动调序。
  - 期望：命中的是**排在上面**那条的动作。

- [ ] **2.3 B4 拦截动作**
  - 步骤：加一条 `主机=ads.* → 拦截`（或把某进程整个设成「拦截」）。
  - 期望：目标连接**建不起来**；`连接` 页出现红色「拦截(规则拒绝)」行、0 字节。

- [ ] **2.4 右键单连接指定代理**
  - 步骤：`连接` 页右键某条连接 → 「走代理 / 直连 / 拦截」。
  - 期望：`规则表` 里立刻多一条精确规则（该进程 × 该主机 × 该端口），之后同类连接按它走。

---

## 3. 连接可观测性（日志 + 持久化 + 抓包 + 流量统计）

- [ ] **3.1 每连接日志实时刷新**
  - 期望：有流量时 `连接` 页每条 TCP 连接一行，含 进程 / 目标 host:port / 走向(直连/代理·协议) / 状态点 / 上下行字节，最新在前。

- [ ] **3.2 A3 连接日志重启不丢**
  - 步骤：产生若干连接 → 退出 app → 重开。
  - 期望：`连接` 页仍显示上次的历史行（最近 200 条，从 `~/Library/Application Support/appidge/connections.log.jsonl` 回灌）。

- [ ] **3.3 .dmp 逐连接抓包**
  - 步骤：`连接` 页头部打开「抓包(.dmp)」开关 → 产生一些代理流量 → 关掉。
  - 期望：App Group 容器 `captures/` 下出现 `<进程_主机_端口_时间>.dmp` 文件；用块格式
    `[方向1B][长度4B 大端][原始字节]` 能解出上下行内容。关开关后不再新增。

- [ ] **3.4 C9 全局流量显示**
  - 期望：菜单栏显示累计 ↑/↓ 总量；`活动监视器` 表头显示累计 + **实时速率**（随流量跳动）+ 最活跃进程正确。

---

## 4. UDP / QUIC（A1 止漏 + A1b 真代理）

- [ ] **4.1 A1：网络设置真的拦截了（这是「拦截从未配置过」第一次真机检验）**
  - 说明：`startProxy` 现在应用 `NETransparentProxyNetworkSettings`（拦所有出站 TCP+UDP、回环除外）——
    此前完全没设置。这条过了，才说明整套代理真的在接管流量。
  - 期望：proxied 应用的 TCP 被接管（§1 已验证即隐含此条）；回环流量不被拦（本地开发正常）。

- [ ] **4.2 A1：默认「拦截」止住 QUIC 泄漏**
  - 准备：`目录` 页 UDP 策略 = **拦截止漏**（默认）。
  - 步骤：让一个 proxied 的浏览器访问支持 HTTP/3 的站点（如 Google/YouTube），抓 UDP 443。
  - 期望：本地**看不到**该进程的 UDP 443 直连；浏览器**回落 TCP** 走代理（出口 IP = 上游）。

- [ ] **4.3 A1：直连进程的 UDP 不受影响**
  - 期望：没被设成代理的 app，其 UDP（DNS、QUIC 等）照常直连、可用。

- [ ] **4.4 A1b：策略「直连放行」**
  - 步骤：UDP 策略切「直连放行」。
  - 期望：proxied 应用的 UDP 恢复直连可用（代价是可能暴露访问目标——这就是这个逃生口的意义）。

- [ ] **4.5 A1b：策略「SOCKS5 代理」真的把 UDP 代理出去** ⭐ 重点
  - 准备：一台**支持 UDP ASSOCIATE** 的 SOCKS5 上游（**Shadowsocks / v2ray / Clash 支持；`ssh -D` 不支持**）。
  - 步骤：UDP 策略切「SOCKS5 代理」+ active 上游是这台 SOCKS5 → proxied 应用发 UDP/QUIC。
  - 期望：UDP 数据报**经代理出去**（relay 端能看到），不本地泄漏；出口是上游。
  - 边界：上游**不是** SOCKS5 时（如 HTTP CONNECT），自动**退回拦截**（不泄漏）。

---

## 5. 多上游路由（P2：链 / 故障转移 / 负载均衡）

- [ ] **5.1 代理链 chain**
  - 准备：≥2 台真上游（可混协议：一台 SOCKS5 + 一台 HTTP）。
  - 步骤：`代理服务器` 页路由模式选「代理链」，按编号勾选顺序。
  - 期望：连接逐跳穿通（client → 上游1 → 上游2 → 目标）；目标侧看到的出口是**链尾**上游。
  - 待回填：**混合协议链**（SOCKS5→HTTP→目标）握手时序是否稳（§9.2）。

- [ ] **5.2 故障转移 failover**
  - 步骤：把候选里第一台设成连不上的地址。
  - 期望：自动落到第二台；**全部** down 时 fail-open（关掉该流、不卡其它流量）。

- [ ] **5.3 负载均衡 loadBalance**
  - 步骤：配 ≥2 台，发多条连接。
  - 期望：连接在上游间轮流（可在两台上游侧看命中分布）。

- [ ] **5.4 连接日志的协议标签**
  - 说明：多台模式下 `连接` 页的协议标签取「首跳」kind；负载均衡实际选台逐连接轮转，标签是近似展示。
  - 待回填：是否需要改成「实际所用那台」（要的话让 `ProxyDialer` 把选中 kind 回传给事件，§9.3）。

---

## 6. 健壮性（转发环 + 诊断器）

- [ ] **6.1 A2：自己组件的流量强制直连（转发环硬化）**
  - 期望：app / 扩展自己发起的连接，在 `连接` 页记为 **direct**（不被自己抓回来代理）。
  - 依赖 §9.1（sourceAppSigningIdentifier 的实际粒度）。

- [ ] **6.2 主动环检测告警**
  - 步骤：**故意**把一台上游配成回环地址、制造转发环（或把上游排除关掉再制造）。
  - 期望：短时间内同目标被反复捕获 → 窗口顶部弹**红色告警条**，可「忽略」。
  - 待回填：阈值现在是 50 次 / 1s（真实环每秒上千次），真机上是否需要微调（§9.4）。

- [ ] **6.3 诊断器 6 类**
  - 步骤：`活动监视器` 每行点「诊断」。
  - 期望：规则命中 / 是否真走代理 / 上游可达 / DNS 解析 四项给出真实结果；UDP·QUIC 泄漏、env 冲突两项
    诚实标注为「未覆盖 / 只能读扩展自身环境」（这是架构限制，不是 bug）。

---

## 7. 代理探活 + 多 profile

- [ ] **7.1 B5 单代理探活「测试」按钮**
  - 步骤：`代理服务器` 每行点「测试」。
  - 期望：能连上的上游 → 绿勾；连不上/超时（3s）→ 红叉。

- [ ] **7.2 多 profile 存 / 载 / 删**
  - 步骤：`档案` 页「存为新档案」把当前配置存一份 → 改点配置 → 「载入」另一个档案。
  - 期望：载入后当前状态被**干净替换**成该档案（不是叠加）；active 档案打勾；删除 active 后 active 落到剩下第一个。

---

## 8. 打包公证（需要你的凭据）

- [ ] **8.1 填公证凭据**
  - 在 `.env` 里二选一填：Apple ID + App 专用密码（`NOTARY_APPLE_ID` / `NOTARY_APP_SPECIFIC_PASSWORD`），
    或 App Store Connect API key（`NOTARY_API_KEY_PATH` / `NOTARY_API_KEY_ID` / `NOTARY_API_ISSUER_ID`）。
    脚本里有详细说明（去哪个网页生成、填成什么样）。`.p8` 已被 `.gitignore` 忽略。

- [ ] **8.2 跑归档 + 公证**
  - 步骤：`./scripts/archive-and-notarize.sh`（archive → exportArchive → `notarytool submit --wait` → `stapler staple`）。
  - 期望：`build/export/appidge.app` 已签名、公证、staple，可分发。前提是 §0.1 的 capability 已开。

---

## 9. 待你回填的开放问题

- [ ] **9.1 `sourceAppSigningIdentifier` 的粒度**（loop 里明确不许瞎猜的那条）
  - 问题：flow metadata 拿到的进程身份，是 **CLI 子进程级**（如 `curl`）还是只到**父 app 级**？
  - 影响：决定「按进程」的规则/排除到底能细到什么程度。跑 §0.3 的 smoke 脚本后把观测结果回填这里。

- [ ] **9.2 混合协议代理链的握手时序**（§5.1）——真机确认 SOCKS5→HTTP→目标 是否稳。

- [ ] **9.3 多上游模式下连接日志协议标签**（§5.4）——是否要从「首跳」改成「实际所用那台」。

- [ ] **9.4 主动环检测阈值**（§6.2）——50 次 / 1s 在真机上是否合适，误报/漏报如何。

---

## 附：本轮明确**未做**（非遗漏，是取舍）

- **SOCKS4/4A**：1996 年被 SOCKS5 取代，现实几乎无人用 → 砍。
- **HTTPS 的 NTLM / Kerberos 认证**：手搓重加密 / 需 GSS.framework、niche → 砍。
- **便携版**：系统扩展必须安装，无安装的便携版架构上不可能 → 砍。
- **CI**：私有仓库 macOS Actions 分钟数已耗尽（job 3 秒 0 步骤失败）。恢复：加 Actions 分钟 / 仓库转 public /
  挂 self-hosted runner。本会话后期改为「本地全绿即合」（本地 `swift test ×5 + swiftlint --strict + xcodebuild`
  是 CI 的超集）。

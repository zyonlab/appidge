# Proxifier 功能对齐文档

> 调研对象：Proxifier（[proxifier.com](https://www.proxifier.com/)，
> [features](https://www.proxifier.com/features.html)、
> [Mac v2 文档](https://www.proxifier.com/docs/mac-v2/)）。
> 对齐对象：本项目 appidge（macOS 按进程代理，`NETransparentProxyProvider` 系统扩展）。
> 目的：以 Proxifier 这个成熟标杆为参照，把「我们已经有什么 / 差什么 / 差距有多要命」
> 摊开，特别是用户指出的三点——**没有配置代理的地方**、**进程流量转发日志**、
> **转发循环管理**、**本地开发访问本地**。

---

## 0. 一句话结论

appidge 目前把**「按进程做决策」的架构骨架**做得很扎实（单向数据流、actor 隔离、
系统扩展真实转发、诊断、回环排除、持久化都在），但**「代理」这半件事本身还没成形**：

- **没有配置上游代理的任何地方**——上游写死在扩展里（`127.0.0.1:1080`），UI 里连
  一个填代理地址的输入框都没有。这正是你看到的「UI 都没有配置代理的地方」。
- **`.proxied` 规则目前并不会真的把流量转发去上游代理**——转发路径永远是「直连到
  目的地」，规则只影响计量和诊断的标签，不影响实际走向（见 §5）。
- 规则只能**按进程**匹配，Proxifier 能按 **应用 + 目标主机 + 端口** 三个维度匹配。

也就是说：Proxifier 的核心价值「让不支持代理的程序走 SOCKS/HTTPS 代理」，我们**还没
真正实现**，现在实现的是「按进程把 TCP 流接管下来、计量、诊断、回环放行」。下面逐项对齐。

---

## 1. 拦截机制（架构层）

| 维度 | Proxifier | appidge 现状 | 差距 |
|---|---|---|---|
| 拦截方式 | macOS 上历史用 NKE（网络内核扩展），新版转向系统扩展 | `NETransparentProxyProvider` 系统扩展（Apple 官方现代方案，免 kext、可公证） | ✅ 我们用的是更现代、更"面向未来"的路子，这一层不吃亏 |
| 覆盖协议 | 所有出站 **TCP** | 所有出站 **TCP**（`NEAppProxyTCPFlow`） | ⚠️ 双方都只做 TCP；UDP/QUIC 都不管（我们诊断里诚实标了这条限制） |
| 进程识别 | 按可执行文件名（支持通配符） | 按 `sourceAppSigningIdentifier`（bundle id / 签名标识） | ✅ 签名标识比文件名更稳（改名/多版本不易误判），这点我们更好 |

**结论**：拦截机制这层我们不落后，甚至在"进程识别稳健性"和"免 kext"上更优。问题都在
拦截**之后**怎么处理。

---

## 2. 代理服务器配置 ⭐（最要命的差距）

| 维度 | Proxifier | appidge 现状 | 差距 |
|---|---|---|---|
| 代理类型 | SOCKS4 / SOCKS4A / SOCKS5（含用户名密码认证）/ HTTPS（Basic·Kerberos·NTLM）/ HTTP | **无**——上游写死 `127.0.0.1:1080`，且没有实现任何代理协议客户端 | 🔴 P0 |
| 配置界面 | 专门的「Proxy Servers」对话框：地址、端口、协议、认证、标签（label） | **完全没有**——UI 里没有任何填代理的地方 | 🔴 P0 |
| 认证 | 各协议对应的用户名密码 / 域认证 | 无 | 🔴 P0 |
| 代理探活 | Proxy checker，逐个测可用性 | 诊断器有 `upstreamReachable`（TCP 探活 `127.0.0.1:1080`），但探的是写死的地址 | 🟡 有雏形，缺 UI + 多代理 |

这就是你直接点破的问题。要让 appidge 名副其实，**必须先有**：
1. 一个 `ProxyServer` 领域模型（host / port / kind: socks5·https·http / 可选认证）。
2. 一个配置界面（"代理服务器"这一区，能增删改）。
3. 真正的代理协议客户端实现（至少先 SOCKS5，最常用、最简单）。

没有这三样，"代理"就只是个开关标签。详细方案见 §12 路线图 P0。

---

## 3. 代理链与冗余

| 维度 | Proxifier | appidge 现状 | 差距 |
|---|---|---|---|
| 代理链（chain） | 任意长度、混合协议、拖拽排序、可整链启停 | 无 | 🟢 P2（高级功能，先不急） |
| 故障转移（failover） | 冗余列表，主代理挂了自动切备用 | 无 | 🟢 P2 |
| 负载均衡 | 链内可配 | 无 | 🟢 P2 |

**结论**：这些是 Proxifier 的高级卖点，对 MVP 不是刚需，等 §2 落地后再说。

---

## 4. 代理规则

| 维度 | Proxifier | appidge 现状 | 差距 |
|---|---|---|---|
| 匹配维度 | **应用 + 目标主机 + 目标端口** 三者组合 | **仅按进程**（`assignRule(processID, rule)`） | 🔴 P1 |
| 通配 / 范围 | 应用名通配、主机通配、IP 段、端口段 | 无（进程要么整个直连要么整个代理） | 🟡 P1 |
| 动作（action） | Direct / Proxy / **Chain** / **Block** | 仅 Direct / Proxied（两种） | 🟡 缺 Block、Chain |
| 处理顺序 | 规则从上到下匹配，顺序有意义 | 无"规则表"概念，每个进程一条独立设置 | 🟡 P1 |
| 默认规则 | 特殊「Default」规则兜底（只能改 action） | 有全局开关 + 每进程默认 `.direct`，语义接近但没有显式"默认规则"对象 | 🟢 差不多够用 |
| 手动/动态代理 | 右键给某连接临时指定代理 | 无 | 🟢 P2 |

**关键差距**：真实世界里你经常想说"**Chrome 访问 `*.google.com` 走代理，其它直连**"——
这需要「应用 × 目标主机」的组合规则。我们现在只能说"Chrome 整个走代理 or 整个直连"，
粒度太粗。这是 §2 之后第二重要的事（P1）。

---

## 5. 流量转发（实际转发路径）⭐

| 维度 | Proxifier | appidge 现状 | 差距 |
|---|---|---|---|
| `.proxied` 时的实际走向 | 通过配置的 SOCKS/HTTPS 代理转发 | **仍然直连到目的地**——`relay(to: tcpFlow.remoteFlowEndpoint)` 永远拨的是流的真实目的地，不是上游代理 | 🔴 P0 |
| `.direct` 时的走向 | 直连 | 直连 ✅ | — |
| 计量 | 每连接收发字节 | actor `FlowRouter` 按 500ms 批量聚合，每进程上下行字节 ✅ | ✅ 这块我们做得不错 |

**必须点明**：这是全项目最容易被误解为"已完成"的地方。目前
`rule == .proxied` **只**影响 `router.route(..., rule:)` 传给计量/路由历史的标签，
以及诊断显示——**字节转发本身对 direct 和 proxied 一视同仁，都是直连目的地**。
换句话说，把某个 app 设成"代理"，它的流量**并不会真的走代理**。

这条和 §2（没有代理可配）是同一个根：**上游代理协议客户端没实现**。做完 §2 的
SOCKS5 客户端后，`relay` 要改成：`rule == .proxied` 时先连上游代理、按 SOCKS5 握手
把目的地址发过去、再双向转发；`.direct` 时保持现在的直连。PROGRESS.md 里已经诚实
记了这条遗留，这里再对齐强调一次它的优先级是 P0。

---

## 6. 回环与转发循环管理 ⭐（你问的两点，我们表现分化）

### 6a. 本地回环 / 本地开发访问本地（我们已对齐 ✅）

| 维度 | Proxifier | appidge 现状 |
|---|---|---|
| localhost/回环处理 | 内置「Localhost」规则：*"When this rule is enabled, Proxifier does not tunnel local connections (loopbacks)"*，默认让 `127.0.0.1` 走直连 | `LoopbackDetector` 用 POSIX `inet_pton` 严格判定 `127.0.0.0/8`、`::1`、`localhost`，命中就**强制 `.direct`，无视分配的规则**——在真实字节转发路径上生效 |

**结论**：你担心的"本地开发访问本地"（比如开发时访问 `https://localhost:3000`、
`127.0.0.1` 上的服务）我们**已经处理好了**，语义和 Proxifier 的 Localhost 规则一致。
唯一小差距：Proxifier 把它做成一条**用户可见、可编辑**的规则（虽然不建议改），
我们是写死在检测器里、UI 不可见。可以后续把它提升成 UI 里一条只读/可选的"本地直连"开关。
一个已知的边界：`::ffff:127.0.0.1`（IPv4-mapped IPv6）我们**故意不算**回环，有测试钉住，
以后要改是显式 diff。

### 6b. 转发循环（无限环）管理（我们只做了一半 ⚠️）

Proxifier 明确处理这个问题，定义也很清楚：

> *"A proxy connection loop occurs when Proxifier captures a connection, redirects it to a
> local proxy server, which then re-initiates the connection—only for Proxifier to capture
> and redirect it again... In the worst case, network access can be completely blocked."*

Proxifier 两手抓：
1. **预防性配置**：*"Proxifier should be configured to bypass connections made by local proxy"*
   ——让本地代理自己发起的连接绕过代理。
2. **主动检测**：「Infinite Connection Loop Detection」持续监控，检测到就**阻断所有新连接
   并弹窗**让用户处理。

| 维度 | Proxifier | appidge 现状 | 差距 |
|---|---|---|---|
| 回环地址绕过（预防） | Localhost 规则 + 让本地代理连接绕过 | `LoopbackDetector` 让 `127.0.0.1:1080`（我们的上游）这类回环强制直连——**恰好**部分挡住了"扩展连本地代理又被自己抓回来"的环 | 🟡 部分覆盖 |
| 按"发起进程是代理自己"绕过 | 有（bypass connections made by local proxy） | **无**——没有"我们扩展自己/上游代理进程发起的连接不再接管"的显式排除 | 🟡 P1 |
| 主动无限环检测 + 阻断 | 有，自适应监控 + 弹窗 | **无** | 🟢 P2 |

**结论**：因为我们上游写死在 `127.0.0.1:1080`，而 `LoopbackDetector` 会把到
`127.0.0.0/8` 的连接强制直连，所以"扩展 → 本地代理"这一跳**目前碰巧不会**被再次
代理——环被回环排除挡住了。但这是**巧合式**的安全，不是设计上的循环管理：一旦上游
代理配成非回环地址（比如公司内网 `10.x` 的代理），这层保护就失效了。真正健壮的做法
（§2 落地、上游可配之后立刻要补）：
- **按上游代理的地址 + 端口显式排除**：凡是目的地 == 当前配置的任一上游代理，强制直连。
- **按发起进程排除**：我们扩展自己（以及上游代理进程，如果在本机）发起的连接不接管。
- 可选的自适应环检测（P2）。

---

## 7. DNS / 名称解析

| 维度 | Proxifier | appidge 现状 | 差距 |
|---|---|---|---|
| System DNS | ✅ | 由系统解析（我们在 TCP flow 层，目的地已是解析后的 endpoint） | — |
| DNS over proxy | ✅（把 DNS 查询也through代理，防 DNS 泄漏） | 无 | 🟡 P1（和"真代理"配套，否则 DNS 泄漏） |
| 混合模式 / DNS 排除表 | ✅ | 无 | 🟢 P2 |
| DNS 诊断 | — | 诊断器有 `dnsResolution`（真实解析探测） | ✅ 诊断侧我们反而有 |

**结论**：等 §2 真代理落地后，DNS-over-proxy 要跟上，否则"走了代理但 DNS 还是本地明文
查"会泄漏访问目标。现在没有真代理，这条还不紧迫。

---

## 8. 连接监控与日志 ⭐（你问的"进程流量转发日志"）

| 维度 | Proxifier | appidge 现状 | 差距 |
|---|---|---|---|
| 实时连接视图 | 每条连接一行：**应用名、目标主机、时间/状态、命中的规则/代理、收发字节** | 「活动监视器」只有**每进程聚合**的上下行字节（↑0B ↓0B）+ 规则选择 + 诊断按钮 | 🟡 P1 |
| 粒度 | **每连接** | **每进程**（多条连接被聚合成一个进程一行） | 🟡 P1 |
| 日志文件 | Errors Only / Normal / Verbose / Verbose and Traffic 四档，写 `~/Library/Logs/Proxifier` | **无日志文件** | 🟡 P1 |
| 流量抓包 | `.dmp` 逐连接抓包（`App(PID) TO host_port AT timestamp.dmp`） | 无 | 🟢 P2 |
| 带宽图 / 全局统计 | 实时带宽曲线 + 全局统计 | 无 | 🟢 P2 |
| 状态栏 | 托盘图标显示流量 | 有 `MenuBarExtra`（菜单栏），但只有全局开关，不显示流量 | 🟢 P2 |

**结论**：你说的"进程流量转发日志"我们只做到了**每进程字节计数**这个最粗的层次。
Proxifier 的核心可观测性是**每连接一行、带目标主机/端口/命中规则/所用代理/状态**的实时
表格 + 可落盘的日志。这是排查"这个 app 到底走没走代理、走的哪个、连的哪个目标、成没成功"
的关键工具。建议 P1 补：
- 让扩展上报**每连接**元数据（目的 host:port、命中规则、direct/proxied、起止时间、字节、
  成功/失败），不只是聚合字节。
- App 侧存成一个可查看、可导出的连接日志（内存环形缓冲 + 可选落盘 Verbose）。
- 我们已有的 IPC 批量上报管线（`FlowStatsBatchMessage` / `FlowRouter`）是现成地基，
  扩成"连接事件流"即可，不用重起炉灶。

---

## 9. 诊断（我们反而更强的地方 ✅）

Proxifier 的诊断偏"日志 + 代理探活 + 环检测弹窗"。appidge 有一个**结构化诊断器**
（`DiagnosticsRunner`），按 CLAUDE.md 第 5 节实现了 6 类：

| 诊断项 | appidge | 说明 |
|---|---|---|
| 规则命中 ruleHit | ✅ | 查当前应用规则集 |
| 是否真走代理 actuallyProxied | ⚠️ | 有 `RoutingHistoryTracker`，但因 §5"没真代理"，语义暂时受限 |
| 上游可达 upstreamReachable | ✅ | 真实 TCP 探活（现在探写死的上游） |
| DNS 解析 dnsResolution | ✅ | 真实解析探测 |
| UDP/IPv6·QUIC 泄漏 | ⚠️ 诚实标注 | `NETransparentProxyProvider` 只管 TCP，这是架构限制，诊断如实报告"未覆盖" |
| env 冲突 envConflict | ⚠️ 诚实标注 | 只能读扩展自己进程的环境变量，读不到目标 app 的 |

**结论**：诊断是我们相对 Proxifier 更体系化的一块，方向对。等 §2/§5 落地后
`actuallyProxied` 会变得真正有意义。

---

## 10. 配置管理与持久化

| 维度 | Proxifier | appidge 现状 | 差距 |
|---|---|---|---|
| 配置文件 | XML profile（`.ppx`），多 profile 快速切换、静默加载、远程更新 | JSON 持久化（`~/Library/Application Support/appidge/config.json`），存规则/目录/引导标记 | 🟢 单 profile 够用，多 profile 是 P2 |
| 密码加密 | 主密码 / 用户凭据加密 | 暂无（因为还没有代理凭据要存） | 随 §2 一起考虑 |
| 首次引导 | — | 有 OnboardingView + 系统扩展激活 ✅ | ✅ |

---

## 11. 打包与分发

| 维度 | Proxifier | appidge 现状 |
|---|---|---|
| 签名/公证 | 成品商业软件 | Developer ID 签名齐全；`scripts/archive-and-notarize.sh` 骨架就绪（缺人填公证凭据 + Portal 开 System Extension capability） |
| 便携版 / 静默安装 | 有 | 无（P3） |

---

## 12. 建议路线图（按优先级）

### 🔴 P0 — 让"代理"名副其实（没有这些，产品名不成立）
1. **`ProxyServer` 领域模型 + 配置 UI**：host / port / kind（先 SOCKS5）/ 可选认证。
   加一个"代理服务器"设置区（对齐 Proxifier 的 Proxy Servers 对话框）。
2. **SOCKS5 上游客户端**：在扩展的 `relay` 里，`rule == .proxied` 时改为：连上游代理 →
   SOCKS5 握手上报目的地址 → 双向转发；`.direct` 保持直连。这是 §5 那条遗留的兑现。
3. **上游地址显式排除**（循环管理硬化）：目的地 == 任一配置的上游代理时强制直连，
   不再依赖"上游恰好是回环"这个巧合。

### 🟡 P1 — 让它真正好用
4. **组合规则**：应用 × 目标主机 × 端口，带通配/范围，从上到下匹配的规则表
   （对齐 Proxifier Proxification Rules）。
5. **每连接日志**：扩展上报连接级元数据，App 侧连接日志视图 + 可选落盘 Verbose
   （对齐 Proxifier Connections/Log，兑现你要的"进程流量转发日志"）。
6. **DNS-over-proxy**：真代理落地后配套，防 DNS 泄漏。
7. **按发起进程排除**：扩展自己/本机代理进程发起的连接不接管。

### 🟢 P2 及以后
8. 代理链 / 故障转移 / 负载均衡。
9. 主动无限环检测 + 阻断弹窗。
10. 带宽曲线、全局统计、菜单栏流量显示、`.dmp` 抓包。
11. 多 profile、凭据加密、便携版。

---

## 13. 一张图总结对齐度

```
拦截机制        ████████████████████  对齐/更优（免 kext、签名标识）
本地回环处理    ████████████████████  已对齐（LoopbackDetector = Localhost 规则）
计量聚合        ██████████████░░░░░░  有每进程字节，缺每连接
诊断            ████████████████░░░░  更体系化，部分受"没真代理"限制
持久化/引导     ██████████████░░░░░░  单 profile 够用
─────────────────────────────────────────────
代理服务器配置  ░░░░░░░░░░░░░░░░░░░░  🔴 完全没有（你点破的核心）
实际代理转发    ░░░░░░░░░░░░░░░░░░░░  🔴 .proxied 仍直连，没真走代理
组合规则        ████░░░░░░░░░░░░░░░░  🟡 仅按进程
连接级日志      ████░░░░░░░░░░░░░░░░  🟡 只有每进程字节
转发循环管理    ██████████░░░░░░░░░░  🟡 靠回环排除巧合挡住，缺显式上游排除+检测
DNS-over-proxy  ░░░░░░░░░░░░░░░░░░░░  🟡 待真代理落地后配套
代理链/冗余     ░░░░░░░░░░░░░░░░░░░░  🟢 高级功能，暂缓
```

**最短见效路径**：P0 的三步（代理模型+UI、SOCKS5 客户端、上游排除）做完，appidge 就从
"按进程接管 TCP 的骨架"变成"真的能按进程走代理的工具"——这是从 demo 到可用的分水岭。

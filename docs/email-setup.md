# support@appidge.com 邮件收发方案

本文件给出 `support@appidge.com` 的**收信转发**与**以该地址发信/回信**的可执行方案。
域名 `appidge.com` 托管在 Cloudflare。目标:

- 收:发到 `support@appidge.com` 的邮件转发到 `hi@zyoncode.com`。
- 发:能以 `support@appidge.com` 身份回信/发信(退款、支持沟通)。

> 结论先行(indie 单人视角):**收**用 Cloudflare Email Routing(免费、几分钟配好);**发**用一个
> 支持自有域 + SPF/DKIM 的第三方 SMTP 中继绑进 **Gmail 的「作为其他地址发送」**。首选中继
> **smtp2go**(免费 1000 封/月,port 587/465),或若已在用 **Resend**(也可,见下)。Cloudflare
> **新推出的 Email Service 也提供发信 SMTP**(465),但截至 2025 中为 private beta,上线前需先核实
> 你的账户是否已放开——能开就最省事(收发同一家)。

---

## 1. 关键事实(先厘清,避免走弯路)

### 1.1 Cloudflare Email Routing = 只收转发,不发信

- Email Routing 是**入站转发**产品:给自有域配 MX,把到达的邮件转发到已验证的目标邮箱。它
  **不提供出站 SMTP 服务器**,无法用来「以 support@ 发信」。官方与实操指南均明确这一点。
- 它免费、无 cookie、无需自建邮箱,非常适合我们「收 → 转发到 hi@zyoncode.com」的需求。

### 1.2 Cloudflare「Email Service / Email Sending」是另一个产品(会发信)

- 2025 年 Cloudflare 在 Email Routing 之上推出 **Email Service**,新增**出站发信**能力:
  - **Workers API / 绑定**:给 Worker 程序发事务邮件(REST,fetch based)。
  - **认证 SMTP 提交**(Workers 之外可用):`smtp.mx.cloudflare.net`,**端口 465 隐式 TLS**;
    用户名固定为字符串 `api_token`,密码 = 带 `Email Sending: Edit` 权限的 Cloudflare API token。
    发件域必须已在账户里「onboarded for Email Sending」,否则报 `550 5.7.1`。
- 这个 465 认证 SMTP **理论上可直接作为 Gmail「作为其他地址发送」的中继**,实现收发同一家。
  **但**:该服务发布时为 **private beta,可用性按账户放开**;截至撰写(2026-07)文档未标明已 GA。
  **上线前务必在 dashboard 确认 `appidge.com` 能否 onboard Email Sending**。能开 → 用它(见方案 A');
  不能开 → 走 smtp2go/Resend(方案 A)。

### 1.3 为什么不能只靠 Gmail 本身

- Gmail「作为其他地址发送(Send mail as)」**要求填一个能认证发件域的 SMTP 服务器**;Gmail 自己不会
  凭空替你的自有域签名。所以必须挂一个支持自有域 + SPF/DKIM 对齐的中继,否则会带 "via" 横幅、易进垃圾箱。
- Cloudflare Email Routing 没有 SMTP,故必须另配发信中继(smtp2go / Resend / Zoho / Cloudflare Email Service)。

---

## 2. 推荐方案(组合:Cloudflare 收 + smtp2go 发 + Gmail 客户端)

面向单人独立开发者,成本/复杂度最优,且是被广泛验证的路线。

```text
收:  support@appidge.com ──(Cloudflare Email Routing / MX)──▶ hi@zyoncode.com(Gmail)
发:  Gmail「作为其他地址发送」 ──(SMTP 587/465 认证)──▶ smtp2go ──▶ 收件人
                                     发件显示 support@appidge.com,SPF/DKIM 对齐
```

### 为什么 smtp2go(而非 Zoho)

- **smtp2go**:免费 **1000 封/月**,直接给 SMTP 中继凭据 + 自有域 DKIM,配 Gmail send-as 最顺。
- **Zoho Mail 免费版**:限制多(每用户 50 封/天、免费版不含转发、需建真实邮箱),对「只想借 SMTP
  中继」偏重。
- **Resend**:开发者友好,免费 100 封/天(3000/月),自有域 + SPF/DKIM/DMARC;若项目其它地方已在用
  Resend,可复用,见方案 A 变体。Resend 主打 API,但也提供 SMTP(`smtp.resend.com`,587),可绑 Gmail send-as。
- **Amazon SES**:最便宜但按量、初期在沙盒、配置略重,单人支持邮箱场景性价比不突出。

---

## 3. 完整配置步骤

分三处操作:**Cloudflare dashboard(收 + DNS)**、**发信服务(smtp2go / Resend / CF Email Service)**、
**Gmail 客户端(发)**。DNS 记录都落在 Cloudflare(因域名托管在 CF)。

### 3.1 Cloudflare 侧 —— 开 Email Routing(收信)

在 Cloudflare dashboard 操作:

1. 选择 `appidge.com` → 左侧 **Email → Email Routing**(新版路径可能是 **Compute → Email Service →
   Email Routing**)→ **Get started / Onboard Domain**。
2. Cloudflare 会自动添加 **MX 记录**(`*.mx.cloudflare.net`)和一条 **SPF TXT**
   (`v=spf1 include:_spf.mx.cloudflare.net ~all`)。确认添加。
3. **Destination addresses** → 添加 `hi@zyoncode.com` → Cloudflare 发验证邮件到该地址 → 点验证链接。
4. **Routing rules** → **Create rule**:
   - Custom address: `support@appidge.com`
   - Action: **Send to an email** → 目标选 `hi@zyoncode.com`。
   - (可选)开 **Catch-all** 把所有 `*@appidge.com` 都转到 `hi@zyoncode.com`,省得逐个建。
5. 保存。几分钟后给 `support@appidge.com` 发测试邮件,应落入 `hi@zyoncode.com` 收件箱。

> 注意:一个域**只能有一条 SPF TXT 记录**。下一步给发信服务加 include 时,要**合并**进这条,
> 不要新建第二条 SPF。

### 3.2 发信服务侧(选一个)

#### 方案 A — smtp2go(推荐,免费 1000/月)

在 smtp2go 网站操作:

1. 注册 smtp2go 账号,**Settings → Sender Domains** 添加 `appidge.com`。
2. smtp2go 会给出需要添加的 DNS 记录(CNAME 形式的 DKIM + return-path)。
3. **Settings → SMTP Users** 生成一组 SMTP 用户名/密码(发 Gmail 时用)。

对应 **Cloudflare DNS** 添加(在 CF → DNS → Records):

| 类型  | 名称                 | 值                                                   | 说明 |
|------|---------------------|------------------------------------------------------|------|
| CNAME | `s1._domainkey`     | `s1.domainkey.smtp2go.com`                           | DKIM(以 smtp2go 面板给出的实际值为准) |
| CNAME | `s2._domainkey`     | `s2.domainkey.smtp2go.com`                           | DKIM 备用(若面板要求) |
| CNAME | `em`(或面板指定)   | smtp2go 给出的 return-path 目标                        | 回执/对齐(以面板为准) |
| TXT   | `@`                 | `v=spf1 include:_spf.mx.cloudflare.net include:spf.smtp2go.com ~all` | **合并**进已有 SPF,不要新建第二条 |

> DKIM/return-path 的确切主机名**以 smtp2go 面板显示为准**,上表是常见默认。

#### 方案 A 变体 — Resend(若已在用,免费 100/天)

1. Resend → **Domains → Add Domain** `appidge.com`,得到一组 DKIM(TXT/CNAME)与建议的 SPF/DMARC。
2. 在 Cloudflare DNS 添加 Resend 给出的 DKIM 记录;SPF 合并 `include:_spf.resend.com`(或面板给的 include)。
3. SMTP 中继:主机 `smtp.resend.com`,端口 `587`(TLS),用户名 `resend`,密码 = Resend API key。

#### 方案 A' — Cloudflare Email Service 自带 SMTP(收发同一家,先确认可用)

**前置**:在 CF dashboard 确认 `appidge.com` 可 **onboard Email Sending**(非 private-beta gated)。

1. CF → **Email Service → Email Sending** → onboard `appidge.com`(会加 DKIM/SPF,与 Routing 的 SPF 合并)。
2. 建一个 **API token**,权限含 `Email Sending: Edit`。
3. Gmail send-as 里填:
   - SMTP 服务器:`smtp.mx.cloudflare.net`
   - 端口:`465`(隐式 TLS / SSL)
   - 用户名:`api_token`(字面量)
   - 密码:上一步的 API token
4. 优点:收发都在 Cloudflare,DNS 一处、无第三方。缺点:beta 可用性需先坐实,否则回落方案 A。

### 3.3 Gmail 侧 —— 作为 support@appidge.com 发送

用 `hi@zyoncode.com` 登录的 Gmail(邮件已转发到这里):

1. Gmail → **设置(齿轮)→ 查看所有设置 → 账号和导入 → 用这个地址发送邮件 → 添加其他电子邮件地址**。
2. 名称填「Appidge Support」,地址填 `support@appidge.com`;**取消勾选「视为别名(Treat as alias)」**
   (这样对方回信会回到 `support@appidge.com` → 经 Cloudflare 再转回 `hi@zyoncode.com`)。
3. 下一步填 SMTP:
   - smtp2go:`mail.smtp2go.com`,端口 `587`(TLS)或 `465`(SSL),填 smtp2go 的 SMTP 用户名/密码。
   - Resend:`smtp.resend.com`,`587`,用户名 `resend`,密码 = API key。
   - CF Email Service:`smtp.mx.cloudflare.net`,`465`,用户名 `api_token`,密码 = API token。
4. Gmail 发一封验证邮件到 `support@appidge.com` → 经 Cloudflare Routing 转发到 `hi@zyoncode.com`
   收件箱 → 点验证链接 / 填验证码。
5. 完成后,写邮件时「发件人」下拉即可选 `support@appidge.com`;回信时 Gmail 默认用收件地址回,
   也会用 support 身份发出。

---

## 4. SPF / DKIM / DMARC(避免进垃圾箱)

三者要一致才不被判垃圾:

- **SPF**(一条 TXT,`@`):把「收(CF Routing)」与「发(中继)」的 include **合并进同一条**。例:
  `v=spf1 include:_spf.mx.cloudflare.net include:spf.smtp2go.com ~all`。**切勿建两条 SPF**,否则失效。
- **DKIM**:由发信服务(smtp2go/Resend/CF)提供的 CNAME/TXT,让中继能用 `appidge.com` 签名。照面板加。
- **DMARC**(一条 TXT,`_dmarc`):起步用宽松策略,观察对齐后再收紧:
  ```
  _dmarc  TXT  "v=DMARC1; p=none; rua=mailto:hi@zyoncode.com; fo=1"
  ```
  确认 SPF/DKIM 都对齐、无正常邮件被拒后,可逐步升到 `p=quarantine` → `p=reject`。
- 首次配好后用 [mail-tester.com](https://www.mail-tester.com) 或给 Gmail/Outlook 各发一封自测,
  查看邮件原文头里 `SPF=pass`、`DKIM=pass`、`DMARC=pass`。

---

## 5. 操作归属清单(供后续 chrome / dashboard 阶段照做)

| 步骤 | 在哪操作 | 需要的东西 |
|------|---------|-----------|
| 开 Email Routing、加 MX/SPF、验证 `hi@zyoncode.com`、建 support 转发规则 | **Cloudflare dashboard** | CF 账号(域已托管) |
| 加 DKIM / return-path CNAME、合并 SPF、加 DMARC | **Cloudflare DNS** | 发信服务面板给出的记录值 |
| 注册发信服务、添加发件域、生成 SMTP 凭据 | **smtp2go / Resend**(或 CF Email Service) | 邮箱注册;CF Email Service 需先确认账户已放开 |
| 配「作为其他地址发送」、填 SMTP、点验证 | **Gmail 设置** | 上一步 SMTP 凭据;验证邮件会转发到 hi@ |
| 自测 SPF/DKIM/DMARC pass | mail-tester / 自发自查 | — |

> 待人工确认的闸门:①`appidge.com` 是否能 onboard Cloudflare Email Sending(决定用方案 A 还是 A');
> ②发信服务面板给出的 **确切 DKIM/return-path 主机名**(上文为常见默认,以面板为准)。

---

## 参考出处

- Cloudflare Email Routing 只收不发 / 启用步骤 / MX·SPF·DKIM 自动添加:
  <https://developers.cloudflare.com/email-routing/get-started/enable-email-routing/>
- Cloudflare Email Service(发信)与认证 SMTP(465、`api_token`、`Email Sending: Edit`、发件域需 onboard):
  <https://developers.cloudflare.com/email-service/api/send-emails/smtp/> ·
  <https://developers.cloudflare.com/email-service/> ·
  <https://blog.cloudflare.com/email-service/>
- Workers 无法用 SMTP(V8 isolate 无原始 TCP),Workers 外才有 SMTP 提交(仅 465 隐式 TLS):
  <https://developers.cloudflare.com/email-service/api/send-emails/smtp/>
- Cloudflare Routing + Gmail「Send mail as」+ smtp2go 组合与 DNS 表(含「一个域只能一条 SPF」「取消 Treat as alias」):
  <https://sendmailas.com/blog/cloudflare-email-routing-gmail-send-as-guide>
- Zoho 免费版限制 / 组合方案背景:
  <https://medium.com/preprintblog/how-to-send-and-receive-custom-domain-emails-via-gmail-setup-with-zoho-cloudflare-and-it-is-c6a3a41a8196>

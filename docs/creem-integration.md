# creem.io 集成调研 — 原生 macOS App(Developer ID)

> 每条尽量带官方来源 URL;文档未覆盖/推断处标「⚠️需确认」。license API 官方文档清晰;后台开 key、key 送达字段、退款是否自动吊销等处文档薄,需 test 模式实测。

## 0. 一句话结论
creem 满足场景:**MoR 收款 + 自动发 license key + activate / validate / deactivate 三个设备级端点**。Mac app 只需本地「输入 key → activate → 存激活态 → 定期 validate」小状态机。等价于 Lemon Squeezy 的 license API。

## 0.5 实测结论（2026-07-21，test mode 真实 webhook + 官方 API 文档）——**吊销走 validate，不走 webhook**

test mode 抓到真实 `checkout.completed` / `refund.created` / `dispute.created`（脱敏样本见 `contracts/fixtures/creem/*.json`），并核对官方 validate/activate 文档，得到关键事实：

- **webhook 不含 license key**（三种事件都没有），payload 是**订单中心**：`object.order.{id,customer,product}`。
- **validate/activate 响应含 `product_id` 但不含 `order_id`/`customer_id`**；status ∈ `active/inactive/expired/disabled`。
- ⇒ **webhook（有 order 无 license）与 license API（有 license 无 order）没有公共 join key**，无 `license.*` 事件。
  **无法用 webhook 精确吊销某个 license。**

**因此确定的架构（也是官方文档推荐）：**
1. **吊销主路 = validate**：app 定期 validate → facade 调 Creem validate → `status=disabled/inactive` → 映射 `revoked`、`expired`→`expired`。代码已就位（`creem/http.ts normalizeStatus` + `handlers/licenses.ts statusFromCreem`）。
2. **webhook 职责收敛**：验签 + 幂等登记（审计）。不再期望它驱动 per-license 吊销；现有 `revoke_unmapped` 安全路径即正确行为（不凭模糊字段乱吊销）。
3. **Agent C 早期基于「webhook 带 license」写的 refund→revoke-by-fingerprint 测试是虚构场景**，需改写为 validate 驱动（见待办）。

**已查证（Creem 官方 agent skill `SKILL.md`）：无「按 order/customer 查 license」的 API，CLI 也无任何 license 命令**——
只有 activate/validate/deactivate 三个端点。license key 只出现在订单确认/邮件/客户门户，**任何 API 都不返回**。
⇒ order↔license 的程序化桥**不存在**，validate 是**唯一**可能的吊销杠杆。

**唯一未决、必须实测的一点**：**退款后 Creem 是否把 license status 置为 `disabled`？** 文档未明说。
解锁测试（需 license-enabled 产品 + `creem_test_` API key）：**买 → activate → 退款 → validate 看 status**。
- 若变 `disabled/inactive` → validate 主路自动闭环，收工。
- 若仍 `active` → 没有自动/程序化吊销途径。v1 落地方案：**退款时你在 Creem Dashboard 手动 disable 该 license**
  （反正退款本就在 Dashboard 操作），validate 随即返回 disabled → app 锁定。webhook 负责审计/提醒。
  （注意 `deactivate` 只释放实例名额，不等于 disable license key；disable 目前只能在 Dashboard 做。）

## 1. 要不要先做官网?—— 不需要为集成/测试先做
- **注册 + test 模式 + 写全部代码:不需要网站**。免信用卡,test key 前缀 `creem_test_`,无限用。（[introduction](https://docs.creem.io/getting-started/introduction)）
- **上线收真钱**:要过 onboarding/KYC——法律主体、所有权、税务居民地、VAT/税号、business/个人身份。**官方没把「产品官网 URL」列为强制项**。（[Terms](https://www.creem.io/terms)）
- creem 是 MoR，有风控裁量权（"may request additional information at any time"）。**实务上**备一个带产品说明 + 退款/条款/隐私 的轻量落地页能降低被风控卡的概率 ⚠️（行业通例+Terms 推断，非白纸黑字）。
- **建议**:现在就注册拿 test key 写完整套流程（不需网站）；上线前备税务/主体信息（真正 gate）；落地页建议但非必需，**集成和建站并行**。

## 2. 产品 & license key
- 支持**一次性买断**和**订阅**。
- License key 是 **product 级特性**,购买时自动生成 key,带 `activation_limit`(设备数上限,`null`=无限)。
- ⚠️后台「开启 license / 设 activation 数」的具体位置文档薄(部分页 404),在 Product 编辑页找 "License keys / Number of activations"。
- validate 响应有 `status`(active/inactive/expired/disabled)+ `expires_at`(订阅到期即过期,买断为 null)。app 逻辑以这两者为准。

## 3. 结账:两条路
- **A. Checkout Link(推荐起步,无代码)**:后台建产品即得支付链接。app「购买」按钮 → `NSWorkspace.open(url)`。可加 `discount_code`/`metadata` 参数。（[checkout-link](https://docs.creem.io/features/checkout/checkout-link)）
- **B. Checkout API**:`POST https://api.creem.io/v1/checkouts`,头 `x-api-key`,body `product_id`(必填)/`request_id`/`success_url`/`metadata`/`customer.email`。返回 `checkout_url`。（[checkout-api](https://docs.creem.io/features/checkout/checkout-api)）
- **key 送达**:购买确认邮件发给买家 + `checkout.completed` webhook。⚠️确切字段名(`license`/`license_key`)test 模式实测确认。
- **桌面 app 现实做法**:别依赖浏览器付款回跳,**让用户从邮件复制 key 回 app 粘贴**(Lemon Squeezy 桌面 app 标准做法)。
- **回跳签名(若做自动回填)**:`success_url` 带 `checkout_id/order_id/customer_id/.../signature`。⚠️验签是**普通 SHA256**(不是 HMAC!):`sha256_hex("key1=v1|key2=v2|...|salt=<API_KEY>")`(竖线拼、剔空值)。（[checkout-api](https://docs.creem.io/features/checkout/checkout-api)）Mac app 回跳需注册 custom URL scheme,**MVP 不建议**。

## 4. License API(核心,文档清晰)
三端点全 `POST`,头 `x-api-key`,`Content-Type: application/json`。Base:生产 `https://api.creem.io`,测试 `https://test-api.creem.io`。

- **activate** `POST /v1/licenses/activate` — body `{ key, instance_name }`。返回 `status`/`activation`/`activation_limit`/`expires_at` + `instance.id`。**instance.id 必须本地存**,后续 validate/deactivate 都要用。（[activate-license](https://docs.creem.io/api-reference/endpoint/activate-license)）
- **validate** `POST /v1/licenses/validate` — body `{ key, instance_id }`。启动/定期确认 key+设备仍有效(退款/退订后变 inactive/disabled)。（[validate-license](https://docs.creem.io/api-reference/endpoint/validate-license)）
- **deactivate** `POST /v1/licenses/deactivate` — body `{ key, instance_id }`。换机/退出许可时释放名额。（[deactivate-license](https://docs.creem.io/api-reference/endpoint/deactivate-license)）
- 设备数由 product 的 `activation_limit` 控制;超限 activate 报错(⚠️错误码 test 实测)。

## 5. Webhook:退款/拒付/退订 → 吊销
- 后台 **Developers → Webhook** 配置 + 拿 secret。（[webhooks](https://docs.creem.io/code/webhooks)）
- 事件:`refund.created` / `dispute.created` / `subscription.canceled|expired|past_due` / `checkout.completed` / `subscription.active|paid` …
- **验签(HMAC,和回跳不同!)**:头 `creem-signature`,HMAC-SHA256(key=webhook secret,message=**raw body**)。
- **吊销**:需自建后端/serverless 接 webhook。⚠️退款后 creem 是否自动把 key 置 `disabled` 文档未明说 → **上线前实测一单退款看 validate 返回**。稳妥:app 端**依赖定期 validate**命中 creem status 变化来锁功能。
- 桌面 app 无后端时,吊销只能靠 app 定期 validate。

## 6. 离线处理(客户端自设计)
- 激活态本地缓存 `{key, instance_id, product_id, status, expires_at, lastValidatedAt}`。
- **宽限期**:启动 validate;联网成功以返回为准;联网失败且 `now-lastValidatedAt < 7~14 天`放行,超则要求联网。
- **防篡改**:激活标志/关键字段进 **Keychain**,别存明文 plist;可对字段做本地签名(app 内嵌公钥验)。
- **防时钟回拨**:记录单调来源,防调回系统时间无限续宽限。

## 7. 测试模式
完整 sandbox:test key `creem_test_`,base `https://test-api.creem.io`,无需 KYC。整套(activate/validate/deactivate + 退款 webhook)先在 test 跑通。

## 8. SwiftUI Mac app 集成步骤
- **UI**:许可设置面板(TextField 输 key + 激活按钮 + 状态显示 + 本机停用按钮);购买按钮开 checkout link。
- **序列**:购买(开浏览器)→ 粘贴 key → activate(`instance_name`=`Host.current().localizedName`)→ 存 instance.id 到 Keychain → 启动/每日 validate 解锁或锁 → 换机 deactivate。
- **API key 放哪(重要)**:`x-api-key` 是服务端密钥,**嵌进分发 app 会被提取**。最佳实践:**加一层自己的轻量代理(serverless/Cloudflare Worker)持 key**,app 只调代理,代理转 creem;webhook 也落这。纯客户端则 key 会泄露,自行接受风险 + 混淆。

## 9. 后台准备清单
- [ ] 注册(免卡) → 拿 test API key(Settings→API Keys)
- [ ] 建 Product,选买断/订阅,**开 License keys**,设 activation 数
- [ ] 拿该产品 Checkout Link
- [ ] 配 Webhook(Developers→Webhook),记 secret
- [ ] 上线前:完成 onboarding/KYC(税务/主体)
- [ ] (建议非必需)落地页 + 退款/条款/隐私三页
- [ ] 拿 production API key,部署替换

## 10. 风险/坑
1. **两套验签别混**:webhook=HMAC-SHA256(header `creem-signature`);回跳=普通 SHA256(`k=v|...|salt=apiKey`)。以官方 checkout-api 页为准(二手教程有误标 HMAC)。
2. **API key 泄露**:嵌进 app 会被提取 → 强烈建议加自己的代理。
3. **退款自动吊销未文档化** → 上线前实测退款。
4. **key 送达字段名未文档化** → 实测。
5. **后台开 license 文档缺失** → UI 摸索/联系支持。
6. **桌面无天然回跳** → MVP 邮件复制 key 粘贴。
7. **纯客户端授权可逆向绕过** → 独立工具通常可接受,别指望强防护。
8. **费率** 3.9% + $0.40/笔,无月费。
9. **MoR 合规裁量** → 备税务+产品说明。

## 11. Payout 收款方式（Wise / 加密货币）—— 不用垫资
钱流:顾客 → creem → 你。你全程不垫钱(注册免费、无月费、手续费从每笔销售扣、税由 MoR 代收代缴)。唯一变量是「到账时机」。

**官方(creem 定价页)**:每月 **1 号和 15 号**结算,打到**银行账户或加密钱包**;**稳定币 payout 已包含**。（https://www.creem.io/pricing）→ **加密货币收款官方支持**。

**payout 方式与费率**(⚠️ 除官方结算周期外,以下方式/费率来自第三方评测,数字需在后台/向支持核实):
- **PayPal / Wise / Crypto** 三种 payout。
- **加密货币**:USDC(Polygon),抽 **2%** payout 费(收 $10k → 扣 $200)。
- **银行(非 SEPA/欧盟外)**:每笔 **7 EUR/USD 或 1%**,取高者。
- **Wise**:支持,但**部分国家有 Wise 限制** → 注册后在后台 payout 设置确认所在地区可选。
- 收款币种与结算币种不同,会有伙伴方汇率转换费(creem 不控制,未披露比例)。

**结论**:可用**加密钱包(USDC)**或 **Wise** 收款,无需绑传统银行、无需垫资;注意 crypto payout 的 2% 比银行 1% 贵一倍。

### 主要来源
- 概览/费率/test:https://docs.creem.io/ · https://docs.creem.io/getting-started/introduction
- activate/validate/deactivate:https://docs.creem.io/api-reference/endpoint/activate-license · /validate-license · /deactivate-license
- webhooks(HMAC):https://docs.creem.io/code/webhooks
- checkout-api(创建会话 + 回跳 SHA256 验签):https://docs.creem.io/features/checkout/checkout-api
- checkout-link:https://docs.creem.io/features/checkout/checkout-link
- 回跳参数:https://docs.creem.io/llms-full.txt
- KYC/税务:https://www.creem.io/terms
- Payout(结算周期/加密钱包,官方):https://www.creem.io/pricing · https://docs.creem.io/merchant-of-record/supported-countries
- Payout 方式/费率(第三方评测,需核实):https://dodopayments.com/blogs/creem-io-review

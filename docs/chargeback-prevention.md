# 防拒付（Chargeback）Checklist

> 拒付 = 持卡人绕过你、直接找发卡银行强制撤单。一笔 $9.99 拒付实际损失 ≈ 货款 $9.99 + 原手续费 $0.79（不退）+ 约 $25 拒付罚金 ≈ **$35（售价 3.5 倍）**；更严重的是**拒付率**（拒付笔数÷交易笔数）超 ~1% 会触发卡组织罚款 + Polar 限制/冻结账户。
> **头号策略：把退款做得足够顺畅，让人懒得去银行拒付。** 预防 >> 事后抗辩。
> 背景与平台风险见 [[polar-integration]] 与 `docs/polar-risk-assessment.md`（如有）。
> 注：webhook 事件名、Polar 退款/拒付后是否自动 disable license 等**技术行为**以 `apps/api` 迁移实测为准，本文标 `TODO(polar): 待核实` 者不臆造。

## A. 减少拒付动机（最有效）

- [ ] **退款入口显眼**：官网 footer + `/pricing` 购买按钮旁 + `/refund` 页都能一眼看到「如何退款 + 支持邮箱」。（已落地：Footer 联系区、pricing CTA 下的退款提示、refund 页邮件按钮）
- [ ] **支持邮箱真实且秒回**：`support@appidge.com` 必须是**真实、有人看、快速响应**的邮箱。用户能几小时内拿到人工回复，就不会去银行拒付。⚠️ 上线前确认这个邮箱真的收得到、有人回。
- [ ] **明确退款政策**：`/refund` 写清窗口（建议 **14 天无理由全额退**）、如何申请、要附什么（购买邮箱 + license key/订单号）。窗口外 / 明显滥用再按裁量处理。
- [ ] **先试用再买**：下载 / 购买两路 CTA 分开，鼓励先试用 → 降低「买了不合适 → 退 / 拒付」。（已落地）

## B. 降低「认不出账单」拒付（MoR 常见坑）

- [ ] **账单描述符含品牌**：信用卡账单默认显示支付商前缀（Polar 默认描述符字样 `TODO(polar): 待核实`），用户忘了买过 → 以为盗刷 → 拒付。到 **Polar Dashboard → Settings / 联系支持**，把 statement descriptor 设成含 `APPIDGE` 的可识别字样。
- [ ] **购买确认邮件清晰**：邮件里写明商家是 Appidge、买了什么、金额、退款联系方式。

## C. 留证据（抗辩用；数字商品举证难，务必留档）

- [ ] **每单留档**（我们 D1 审计链已具备）：`checkout.completed` 存 order/customer/product/邮箱/时间；激活时存 license 指纹 + instanceName + 时间 + appVersion。
- [ ] **补充可留**：下载日志、激活 IP / UA、条款同意勾选记录、支持沟通往来。
- [ ] 抗辩时能拿出「谁、何时、用什么邮箱买、何时激活、同意了条款」= 有力证据。

## D. 反欺诈（真盗刷）

- [ ] 留意异常单：同一张卡短时多次购买、高风险地区、邮箱异常。
- [ ] 依赖 Polar / 上游（Stripe Radar 等）的基础风控；MoR 会拦一部分。
- [ ] 试用期本身降低盗刷变现动机。

## E. 拒付发生时的 SOP

1. **收到通知**：Polar 发来拒付 webhook 事件（事件名 `TODO(polar): 待核实`；我们 webhook 已能收 + 记 D1）→ 邮件 / Dashboard 也会通知。
2. **及时抗辩（representment）**：在 Polar 给的时限内提交证据（购买邮箱、时间、激活记录、条款同意、支持沟通）。逾期视同放弃。
3. **本地吊销**：拒付到账后，和退款一样在 **Dashboard → Licenses** 把该 license 点 **disable** → validate 返回 revoked → App 锁定（Polar 退款/拒付后是否自动 disable license `TODO(polar): 待核实`，无论上游行为如何本地 deny 都生效，见 [[polar-integration]]）。
4. **复盘**：记录该客户 / 卡，重复拒付者拉入本地 deny-list（D1 revoked 状态优先于上游 active）。

## F. 监控红线

- [ ] **盯拒付率 < 1%**（卡组织硬上限 ~0.9%–1%）。新的小账户几笔就可能顶爆 → 触发 Polar 风控。
- [ ] 拒付率异常升高时：收紧新客风控、加强试用引导、排查是否被盯上刷单欺诈。

---

## 与本仓库系统的对接点（已具备 / 待接）

| 能力 | 状态 |
|---|---|
| 每笔 checkout / 激活进 D1（抗辩证据） | ✅ 已具备（apps/api） |
| `dispute.created` / `refund.created` webhook 接收 + 幂等记账 | ✅ 已具备 |
| 官网显眼退款 + 支持邮箱入口 | ✅ 本次落地（footer / pricing / refund） |
| 客户端离线宽限 + 本地授权缓存（Polar 故障不立即断） | ✅ 已具备（7 天 grace） |
| 本地 revoked 优先于上游 active（deny-list） | ✅ 已具备 |
| 账单描述符含 APPIDGE | ⏳ 人工：Polar 后台设置 |
| 退款/拒付后手动 disable license | ⏳ 人工 SOP（Polar 是否自动 disable `TODO(polar): 待核实`） |
| 支持邮箱真实可达 | ⏳ 人工：确认 support@appidge.com 收发正常 |

> 退款政策的具体窗口/条款为**运营 + 法务决策**，`/refund` 页已标注草稿待终审。

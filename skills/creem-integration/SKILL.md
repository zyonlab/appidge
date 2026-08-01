---
name: creem-integration
description: Creem（creem.io，Merchant of Record）支付与 license 系统接入的实战经验：API/webhook 的文档没写全的真实行为、吊销与退款的正确架构、防拒付运营。凡是接入 Creem 的 checkout/license API/webhook 验签、给桌面或独立开发者产品做付费授权系统（激活/校验/吊销/离线宽限）、设计 MoR 支付的退款与拒付流程，或调试「webhook 验签失败/退款后 license 还能用」类问题时，务必先读本 skill——多条结论与官方文档直觉相反，全部来自 test 模式全链路实测。
---

# Creem / MoR 支付接入实战经验

> 时效声明：以下是 2026-07 test 模式实测结论。实施前仍应以 docs.creem.io 官方文档 + 你自己的
> test 模式实测复核——支付商行为会变，fixtures 必须来自真实捕获而不是按文档猜。

## 架构总纲

- 客户端**绝不直连** Creem API（key 型接口）：自建 facade（如 Cloudflare Worker）持有
  `CREEM_API_KEY`，客户端只调 facade。App 流程 = 输入 key → activate（存 instance id）→
  每日 validate → deactivate。
- facade 错误模型收敛成固定枚举（invalid_request / invalid_license / activation_limit /
  expired / revoked / rate_limited / upstream_unavailable / internal_error），不透传上游响应。
- **未知/缺失状态一律按 transient 进离线宽限，绝不误翻成 revoked**——支付商临时故障不能
  锁死付费用户。客户端缓存最近一次有效授权 + 默认 7 天离线宽限，license key/instance id
  存 Keychain。
- test 模式（`test-api.creem.io`）与生产完全隔离、key 独立，全链路（买→activate→validate→
  退款→disable→validate）都能在 test 模式演练。

## Webhook 的真实行为（与直觉相反的部分）

- 验签是 Creem 自己的方案，**不是 Standard Webhooks**：头 `creem-signature` =
  hex(HMAC-SHA256(secret, 原始请求字节))，恒定时间比较，验签过了才解析 JSON。secret 按
  Dashboard **字面值**用——`whsec_` 前缀不剥离、不 base64 解码。
- **没有** `webhook-id`/`webhook-timestamp` 头 → 无时间窗可校验，防重放只能靠 payload 顶层
  事件 ID（`evt_...`）在数据库的唯一约束做幂等：重复投递返回成功但不重复执行副作用。
- 事件信封 `{ id, eventType, created_at, object }`，业务字段在 `object` 下。
- **webhook 与 license 之间没有公共 join key**：`checkout.completed` / `refund.created` /
  `dispute.created` 都**不带 license key**，license API 又查不到 order——**无法用 webhook
  精确吊销 license**。webhook 只做验签 + 幂等落库审计 + 按 order 记退款 tombstone。
- 用 `CREEM_PRODUCT_ID` 白名单过滤事件；不认识的 product/事件登记后安全忽略。

## 吊销的正确架构

- **吊销主路 = 客户端定期 validate**：退款/拒付时运营在 Dashboard 处理退款的**同时手动
  disable 该 license** → 上游 status=disabled → facade 映射 revoked → App 下次 validate 锁定。
- **退款/拒付不会自动 disable license**（实测：真实退款后 validate 仍返回 active）——手动
  disable 这一步是硬依赖，漏做 = 退款后用户继续用。把它写进运营 SOP。
- **本地 deny 优先于上游 active**：自建 DB 里标 revoked 就直接返回 revoked——这是运营的
  最后杠杆（上游不配合时也能锁）。不要凭邮箱等模糊字段吊销。
- DB 层必测：webhook 重放幂等、乱序事件、退款先于本地 checkout 记录到达、未知 product、
  处理失败后的安全重试。

## 审核/风控/运营

- **拒付率 <1% 是 MoR 账户的生死线**（一笔 $9.99 拒付实际损失 ≈ 3.5 倍售价还计入比率）。
  头号策略是让退款比拒付更容易：退款入口在官网 footer / 定价区 / 退款政策页三处可见，
  短周期无理由退款，邮件即办。
- **账单描述符要含品牌名**——用户看到陌生扣款名会当盗刷直接拒付。
- 客户端 UI 文案**不写死支付商名字**：换 MoR 时不用改客户端与译文（真实项目经历了
  Creem→Polar→Creem 反复，代码里至今留着对方名字的化石变量）。购买按钮只开官网定价页,
  真实 checkout 链接由官网配置持有——换链接不用重发 App。
- 日志与存储全程脱敏：完整 license key 不落 DB（存 HMAC 指纹）、不进日志；对脱敏逻辑本身
  写测试。

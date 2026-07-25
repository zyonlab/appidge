# Appidge production 上线全清单

> 本文是 **production 正式上线的单一操作清单**：逐项列现状与解锁步骤，配合三重生产保护发布链使用。
> 发布入口与命令语义：`ops/README.md`；环境矩阵真相源：`ops/environments/production.conf`；
> Creem 集成基线：`docs/creem-integration.md`；历史证据存档：`docs/commercialization-status.md`。
>
> **纪律**：REQUIRED_ 占位是显式人工闸门，`appidge-ops preflight production` 会 fail-closed 并逐项列出；
> 禁止为通过校验伪造真实值。secret 永远走 `wrangler secret put`，绝不进 git / conf / 日志。

## 现状图例

- **[已备]** 代码/配置已就位，无需人工再动（preflight 不会因此项失败）。
- **[待填]** 需要用户提供 Creem live 非秘密标识后，回填某个 tracked 文件（占位在 git 里，填空即可）。
- **[待配置]** 需要在外部系统（Cloudflare / Creem Dashboard）执行一次性操作，不落 git。

## 一页现状总览

| 类别 | 项 | 现状 | 回填/操作位置 |
|---|---|---|---|
| 域名 | appidge.com / www | [待配置] | Cloudflare 账号加 zone + `deploy-web production` 自动建 DNS/证书 |
| 域名 | api.appidge.com | [待配置] | `deploy-api production` 自动建 |
| 域名 | updates.appidge.com | [待配置] | `publish-updates production` 自动建（当前是孤儿 DNS 记录，背后无 Worker，见 §1） |
| 更新服务 | updates-staging.appidge.com | **[已备]** | 2026-07-25 已部署 `appidge-updates-staging`，build 66 + appcast 上线，`smoke staging` 全绿 |
| 公开配置 | PUBLIC_SITE_URL / API / DOWNLOAD / LICENSE_* / SPARKLE_FEED / SITE_BASE / TRIAL_DAYS | [已备] | `ops/environments/production.conf` |
| 公开配置 | PUBLIC_POLAR_CHECKOUT_URL（Creem live 支付链接） | [待填] | `production.conf` |
| Worker var | MOCK_MODE / CREEM_API_BASE / RATE_LIMIT / MAX_BODY | [已备] | `apps/api/wrangler.toml [env.production.vars]` |
| Worker var | CREEM_PRODUCT_ID（Creem live product id） | [待填] | `apps/api/wrangler.toml [env.production.vars]` |
| Worker secret | CREEM_API_KEY / CREEM_WEBHOOK_SECRET / LICENSE_HMAC_PEPPER | [待配置] | `wrangler secret put … --env production` |
| Webhook | live webhook → `/v1/webhooks/creem` | [待配置] | Creem Dashboard |
| D1 | appidge-licensing-production（id `1db51c0e…`，3 migration） | [已备] | 远端 apply 用 `migrate-api production` 复核 |
| 发布审批 | staging 全链路 smoke 通过 + 三重保护 | [待配置] | 见 §8 |

---

## 1. 域名（4 个，全 Cloudflare custom_domain）

四个 hostname 在 wrangler 配置里 `custom_domain: true`：**wrangler 部署时自动建 DNS 记录 + 签发证书，
前提是 apex 域 `appidge.com` 已加入本 Cloudflare 账号的 zone**（否则部署报 route 绑定失败）。

| Hostname | Worker | 配置位置（已备） | 上线动作 |
|---|---|---|---|
| appidge.com | appidge-web | `apps/web/wrangler.jsonc` env.production.routes | `deploy-web production` |
| www.appidge.com | appidge-web | 同上（第二条 route） | 同上（一次部署两 route） |
| api.appidge.com | appidge-api | `apps/api/wrangler.toml` [[env.production.routes]] | `deploy-api production` |
| updates.appidge.com | appidge-updates | `infra/updates/wrangler.jsonc` env.production.routes | `publish-updates production` |

- **现状**：四条 route 均已在 tracked 配置里 **[已备]**；`preflight` 的拓扑校验已断言它们存在且不与 staging 交叉。
  `appidge.com` zone **已确认在本账号名下**（2026-07-25 核：NS = tricia/hayes.ns.cloudflare.com）。
- **[待配置] 解锁**：DNS/证书由各自 deploy 命令自动完成，无需手动加 A/CNAME。

> ⚠️ **2026-07-25 实测：production Worker 一个都还没部署过。**
> 账号上只存在 `appidge-web-staging` / `appidge-api-staging` / `appidge-updates-staging` 三个；
> `appidge-web` / `appidge-api` / `appidge-updates` 及其 `-production` 变体均 **不存在**，也无 Pages 项目。
> 其中 `updates.appidge.com` 仍留着一条**孤儿 DNS 记录**（代理态 A 记录，背后无 Worker）：
> 边缘缓存未过期时还能返回旧 build 63 的静态资源，缓存一过就是 530 / Cloudflare 1016 Origin DNS error。
> 这不是故障，是「拆分前那次部署的残留」——`publish-updates production` 会重新绑定，无需手工清理。

> ⚠️ **首次自定义域的证书传播远超 10~30s。** 2026-07-25 建 `updates-staging.appidge.com` 实测：
> DNS 立刻生效，但 TLS 证书在各边缘节点上**分批**下发，约 **10 分钟**才做到 10 次连续成功；
> 中间期表现为 `tlsv1 unrecognized name`（SNI 未识别）与 200 交替出现——
> **单次探测通过不等于可用**，务必连续探测确认。
>
> 对发布链的影响：`deploy-api` 的健康检查是 6×8s ≈ 48s，**不足以覆盖首次建域**，
> production 上线时 `api.appidge.com` 极可能在这一步误判失败并中断发布链。
> 建议上线当天要么先单独把四个域建好等证书稳定、再跑发布链，要么临时放宽该重试窗口。

## 2. 公开环境变量（构建期注入 web / Info.plist）

真相源 `ops/environments/production.conf`；`deploy-web` 注入 web build，`build-macos` 注入 Info.plist 并逐项校验。

| 变量 | production 值 | 现状 | 注入去向 |
|---|---|---|---|
| PUBLIC_SITE_URL | https://appidge.com | [已备] | web canonical/OG/sitemap |
| PUBLIC_API_BASE_URL | https://api.appidge.com | [已备] | web + LICENSE_API_BASE_URL 同源 |
| PUBLIC_DOWNLOAD_URL | https://updates.appidge.com/appidge-latest.dmg | [已备] | web 下载 CTA |
| PUBLIC_POLAR_CHECKOUT_URL | REQUIRED_CREEM_LIVE_CHECKOUT_URL | **[待填]** | web 购买 CTA（见 §5） |
| LICENSE_API_BASE_URL | https://api.appidge.com | [已备] | Info.plist LicenseAPIBaseURL |
| LICENSE_CHECKOUT_URL | https://appidge.com/#pricing | [已备] | Info.plist LicenseCheckoutURL（App 内购买跳官网定价锚点；单页 IA 下 `/pricing` 独立页已撤，用锚点避免 404） |
| SPARKLE_FEED_URL | https://updates.appidge.com/appcast.xml | [已备] | Info.plist SUFeedURL |
| SITE_BASE_URL | https://appidge.com | [已备] | Info.plist SiteBaseURL |
| TRIAL_DURATION_DAYS | 7 | [已备] | Info.plist TrialDurationDays（prod 强制 =7） |
| API_D1_DATABASE_NAME | appidge-licensing-production | [已备] | ops 校验/远端查询 |

> 变量名 `PUBLIC_POLAR_CHECKOUT_URL` 沿用自 Polar 时期，实际值是 Creem 支付链接；改名牵动 apps/web
> 构建与 check-site（另一 owner），列为后续债务（`docs/creem-integration.md §8`）。

## 3. Worker 非秘密变量（`apps/api/wrangler.toml [env.production.vars]`）

| var | 值 | 现状 |
|---|---|---|
| MOCK_MODE | false（打真实 Creem live） | [已备] |
| CREEM_API_BASE | https://api.creem.io | [已备] |
| CREEM_PRODUCT_ID | REQUIRED_CREEM_LIVE_PRODUCT_ID | **[待填]**（见 §5） |
| RATE_LIMIT_MAX / RATE_LIMIT_WINDOW_MS / MAX_BODY_BYTES | 60 / 60000 / 16384 | [已备] |
| D1 database_id | 1db51c0e-9d4b-4b32-82f7-e02553508c11 | [已备]（2026-07-24 创建回填） |

## 4. Worker secret（3 个，绝不进 git）

live secret 由用户在 Creem 过 KYC 后从 Dashboard 取得，用 wrangler 注入 production Worker：

```sh
wrangler secret put CREEM_API_KEY        --env production   # Creem live API key（前缀 creem_live_，非 creem_test_）
wrangler secret put CREEM_WEBHOOK_SECRET --env production   # Creem live webhook secret（前缀 whsec_，按 Dashboard 字面值，不剥前缀）
wrangler secret put LICENSE_HMAC_PEPPER  --env production   # license fingerprint pepper（自生成高熵随机串；一经上线不轮换）
```

- 在 `apps/api/` 目录执行（该目录 wrangler.toml 定义了 env.production）。
- **现状 [待配置]**：`preflight production --remote` 会（登录后）核对这三个 secret 名是否存在，
  缺失逐项列出。secret **值**永不被读取/打印。
- `LICENSE_HMAC_PEPPER` 不依赖 Creem，可先自生成注入；另两个待 Creem live 凭证。

## 5. Creem live 待填一览（KYC 通过后「填空即可」）

Creem 是 Merchant of Record，**不需要 Polar 式的 org/benefit ID**——live 只需下面两个非秘密标识 + §4 两个 secret。

| 待填项 | 从哪拿 | 填哪（tracked 文件，占位已就位） | 格式约束 |
|---|---|---|---|
| Creem live **product id** | Creem Dashboard（live 模式）→ 目标产品 → product id | `apps/api/wrangler.toml` → `[env.production.vars]` → `CREEM_PRODUCT_ID` | `prod_` 前缀；非秘密 |
| Creem live **支付链接** | 同一 live 产品 → Share / Payment Link | `ops/environments/production.conf` → `PUBLIC_POLAR_CHECKOUT_URL` | host `creem.io`，**不得含 `/test/`** |

填完这两处，`preflight production` 的 2 项 REQUIRED_ 失败即清零（D1 id 已备，不再报第 3 项）。
product 白名单：webhook 只处理 `CREEM_PRODUCT_ID` 匹配的事件，其余登记后忽略。

## 6. Webhook（live）

- **[待配置]**：Creem Dashboard（live 模式）→ Developers → Webhooks，新增指向
  `https://api.appidge.com/v1/webhooks/creem`（注意路径是 `/creem`，不是历史 `/polar`）。
- secret 即 §4 的 `CREEM_WEBHOOK_SECRET`。验签 = `hex(HMAC-SHA256(secret, rawBody))`，头 `creem-signature`；
  无 webhook-id/timestamp 头，防重放靠 payload 顶层事件 id 幂等登记。
- 处理事件：`checkout.completed`（审计）、`refund.created` / `dispute.created`（order tombstone + 尽力吊销）。
- **退款→吊销依赖运营手动 disable**：Creem 退款不会自动 disable license；退款/拒付时必须在 Dashboard
  同时 **手动 disable 该 license**，App 每日 validate 即锁定（`docs/creem-integration.md §4`）。webhook 仅审计/对账。

## 7. D1

- **[已备]**：`appidge-licensing-production`（id `1db51c0e-9d4b-4b32-82f7-e02553508c11`）已创建；
  3 个 migration（`0001_init` / `0002_polar` / `0003_refund_tombstones`）已应用。
- 上线前用 `preflight production --remote` 或 `migrate-api production`（无 `--apply` = 只读列 pending）复核远端已无 pending。
- 回滚：不做 down migration，用补偿 migration 前滚；Free 层 Time Travel 窗口 7 天，migration 前记录 bookmark。

---

## 8. 三重保护发布序列（每步现状 + 验收 + 回滚点）

production 每个远端写命令必须同时满足，缺一 fail-closed：`--apply` + `--confirm-production` + `APPIDGE_PRODUCTION_APPROVED=YES`。

**发布前置**（无写操作，可随时跑）：

```sh
ops/bin/appidge-ops preflight production --remote   # 逐项列出待填/待配置；REQUIRED_ 全清 + secret/D1 齐才算过
ops/bin/appidge-ops plan production                 # 人工核对 routes / 公开配置 / migration / smoke URL
```

**发布链**（顺序固定，fail-fast；`<N>` = 全局单调递增 build 号，须高于两个 feed 历史最高 build）：

| # | 命令 | 验收（命令内置） | 回滚点 |
|---|---|---|---|
| 1 | `APPIDGE_PRODUCTION_APPROVED=YES appidge-ops migrate-api production --apply --confirm-production` | apply 前打印远端 pending；失败即停，不 deploy | 补偿 migration 前滚；先记 D1 bookmark |
| 2 | `APPIDGE_PRODUCTION_APPROVED=YES appidge-ops deploy-api production --apply --confirm-production` | `pnpm --filter api test` + dry-run；部署后 6×healthz 重试 | 部署前列 deployments；`wrangler rollback --env production` |
| 3 | `APPIDGE_PRODUCTION_APPROVED=YES appidge-ops deploy-web production --apply --confirm-production` | 产物无 staging/sandbox/test 痕迹；含 checkout+download CTA | `wrangler rollback --env production`（web） |
| 4 | `appidge-ops build-macos production --build-number <N>` | build 号单调性（查两 feed）；Info.plist 各 URL/试用值逐项校验；无副作用改写 pbxproj | 本地产物，重跑即可；需更高 build 号 |
| 5 | `appidge-ops prepare-updates production --build-number <N>` | generate_appcast 生成 EdDSA 签名；appcast length=DMG 实际；host 不交叉；≤25MiB | 本地，重跑 |
| 6 | `APPIDGE_PRODUCTION_APPROVED=YES appidge-ops publish-updates production --apply --confirm-production --build-number <N>` | 发布前贴身复查 appcast+route；版本 DMG+latest+appcast 原子上线 | 已下载的错误 build 只能发**更高** build 号修复 |
| 7 | `appidge-ops smoke production` | web 首页/CTA/canonical、api healthz `mockMode=false`、appcast 含 build N 且不交叉、latest.dmg HEAD 200 | 任一失败 → 回滚对应 Worker 后重跑 smoke |
| 8 | `appidge-ops release-manifest production --build-number <N>` | 落 appcast/DMG SHA-256 + gitSha 供审计 | — |

> 一键：`APPIDGE_PRODUCTION_APPROVED=YES appidge-ops release production --apply --confirm-production --build-number <N>`
> （串起 1→8，fail-fast）。首次上线建议分步，便于每步人工核对。
>
> **build-macos 需受控 release Mac** 的 `.env` 签名/公证凭证 + `Config/Signing.xcconfig`；CI/开发机不具备，属人工闸门。
> **系统扩展升级**：staging→prod 共用 Bundle ID/App Group/扩展 ID，旧版→新版真机 Sparkle + 系统扩展重绑
> smoke 仍是人工闸门（`scripts/verify-staging-update.sh`）。

---

## 9. preflight / test 现状（本次核对）

- `bash ops/tests/test-config.sh` → **PASS=82 FAIL=0**（需先 `pnpm install --frozen-lockfile`，否则 node_modules 缺失单项失败为环境问题）。
- `appidge-ops preflight production` → fail-closed，逐项列出 **2 项 REQUIRED_**（`PUBLIC_POLAR_CHECKOUT_URL`、`CREEM_PRODUCT_ID`）；
  D1 database_id 已回填不再报第 3 项。填完 §5 两处后此 2 项清零。

## 10. 剩余人工闸门总表（上线前必须逐项完成）

1. **[用户]** Creem KYC 通过 → live 产品 → 回填 §5 两处（product id + 支付链接）。
2. **[用户]** `wrangler secret put CREEM_API_KEY / CREEM_WEBHOOK_SECRET / LICENSE_HMAC_PEPPER --env production`（§4）。
3. **[用户]** Creem Dashboard 配 live webhook → `https://api.appidge.com/v1/webhooks/creem`（§6）。
4. **[用户/Cloudflare]** 确认 `appidge.com` zone 在本账号（§1）。
5. **[用户]** staging 全链路 smoke 通过（买单→activate→validate→退款+disable→validate=revoked）+ production 发布审批。
6. **[release Mac]** `build-macos` 签名/公证凭证 + 真机系统扩展升级 smoke（§8）。
7. 全部就绪后按 §8 三重保护序列发布，`smoke production` 收尾。

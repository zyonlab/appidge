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
| 域名 | appidge.com / www | **[已备]** | 2026-07-26 `deploy-web production` 上线，两 route 均绑定（需先删孤儿 A 记录，见 §1） |
| 域名 | api.appidge.com | **[已备]** | 2026-07-26 `deploy-api production` 上线，healthz 连续 10 次绿 |
| 域名 | updates.appidge.com | [待配置] | `publish-updates production` 自动建（孤儿 DNS 记录已于 2026-07-26 清掉，见 §1） |
| 更新服务 | updates-staging.appidge.com | **[已备]** | 2026-07-25 已部署 `appidge-updates-staging`，build 66 + appcast 上线，`smoke staging` 全绿 |
| 公开配置 | PUBLIC_SITE_URL / API / DOWNLOAD / LICENSE_* / SPARKLE_FEED / SITE_BASE / TRIAL_DAYS | [已备] | `ops/environments/production.conf` |
| 公开配置 | PUBLIC_POLAR_CHECKOUT_URL（Creem live 支付链接） | **[已备]** | `production.conf`（2026-07-26 回填） |
| Worker var | MOCK_MODE / CREEM_API_BASE / RATE_LIMIT / MAX_BODY | [已备] | `apps/api/wrangler.toml [env.production.vars]` |
| Worker var | CREEM_PRODUCT_ID（Creem live product id） | **[已备]** | `apps/api/wrangler.toml`（2026-07-26 回填 `prod_3DHsihYJeOAhNDOT0Wo0LV`） |
| Worker secret | CREEM_API_KEY / CREEM_WEBHOOK_SECRET / LICENSE_HMAC_PEPPER | **[已备]** | 2026-07-26 注入；`CREEM_API_KEY` 已用 live 探针证明可用（§11） |
| Webhook | live webhook → `/v1/webhooks/creem` | [已配置]（待端到端验证） | Creem Dashboard（2026-07-26 已建；`api.appidge.com` 现已上线，可以重投测试事件了） |
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
  2026-07-26：`appidge.com` / `www` / `api` 三条 route **已实际绑定上线**，`updates` 待 `publish-updates`。
- **[待配置] 解锁**：DNS/证书由各自 deploy 命令自动完成，无需手动加 A/CNAME。

> ⚠️ **2026-07-26 实测：孤儿 A 记录会让 custom domain 绑定直接失败（code 100117）。**
> `deploy-web production` 报 `Hostname 'appidge.com' already has externally managed DNS records
> (A, CNAME, etc). Delete them first`——Worker 与静态资源**已上传成功**，只是 route 绑不上。
> 原因是 apex/www/updates 上留着拆分环境之前那次部署的手工 A 记录（当时 apex 返回 522、
> www 返回 525、updates 完全超时，背后早已无源站）。
> **解法**：在 Cloudflare Dashboard 删掉这三个名字的 A/CNAME 记录后重跑 deploy，wrangler 会自建托管记录。
> **别碰** MX（`eforward1~5.registrar-servers.com`，Namecheap 邮件转发，删了收不到 Creem 订单/退款通知）、
> 任何 TXT（SPF/DKIM/域名验证）和 NS。
> 三条孤儿记录已于 2026-07-26 清理完毕 ⇒ `updates.appidge.com` 下次 `publish-updates` **不会**再撞 100117。
> wrangler 的 OAuth token 只有 `zone:read`，**没有 `dns_records:write`**（实测列记录 403），
> 这一步只能人工在 Dashboard 做或另发一个 scoped API token。

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
>
> **2026-07-26 production 实测修正**：`api.appidge.com` 约 **30 秒**就稳定（DNS 传播完即通，
> 未出现 staging 那次的 `tlsv1 unrecognized name` 分批下发）——差别在于 `appidge.com` zone
> 早已 active 且有代理记录，不是全新 zone。但 `deploy-api` 的 48s 窗口**仍然踩空**：
> 前 6 次全是 `Could not resolve host`，命令以 `ERROR: healthz 连续 6 次失败` 退出，
> **而 Worker 其实已经部署成功**。⚠️ 这一步失败**不是回滚信号**——先用连续探测
> （建议 10 次连续 200 才算通过，单次 200 不作数）确认，再决定要不要 rollback。

## 2. 公开环境变量（构建期注入 web / Info.plist）

真相源 `ops/environments/production.conf`；`deploy-web` 注入 web build，`build-macos` 注入 Info.plist 并逐项校验。

| 变量 | production 值 | 现状 | 注入去向 |
|---|---|---|---|
| PUBLIC_SITE_URL | https://appidge.com | [已备] | web canonical/OG/sitemap |
| PUBLIC_API_BASE_URL | https://api.appidge.com | [已备] | web + LICENSE_API_BASE_URL 同源 |
| PUBLIC_DOWNLOAD_URL | https://updates.appidge.com/appidge-latest.dmg | [已备] | web 下载 CTA |
| PUBLIC_POLAR_CHECKOUT_URL | https://www.creem.io/payment/prod_3DHsihYJeOAhNDOT0Wo0LV | **[已备]** | web 购买 CTA（2026-07-26 回填；尾部 product id 与 §3 一致） |
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
| CREEM_PRODUCT_ID | prod_3DHsihYJeOAhNDOT0Wo0LV | **[已备]**（2026-07-26 回填） |
| RATE_LIMIT_MAX / RATE_LIMIT_WINDOW_MS / MAX_BODY_BYTES | 60 / 60000 / 16384 | [已备] |
| D1 database_id | 1db51c0e-9d4b-4b32-82f7-e02553508c11 | [已备]（2026-07-24 创建回填） |

## 4. Worker secret（3 个，绝不进 git）

live secret 由用户在 Creem 过 KYC 后从 Dashboard 取得，用 wrangler 注入 production Worker：

```sh
wrangler secret put CREEM_API_KEY        --env production   # Creem live API key
wrangler secret put CREEM_WEBHOOK_SECRET --env production   # Creem live webhook secret（前缀 whsec_，按 Dashboard 字面值，不剥前缀）
wrangler secret put LICENSE_HMAC_PEPPER  --env production   # license fingerprint pepper（自生成高熵随机串；一经上线不轮换）
```

- 在 `apps/api/` 目录执行（该目录 wrangler.toml 定义了 env.production）。
- **key 形态**：test key 是 `creem_test_<alnum>`；**live key 只有一段 `creem_<alnum>`**，没有 `creem_live_`
  这种写法（2026-07-26 拿到真实 live key 后修正；`src/log.ts` 的兜底脱敏正则已同步覆盖单段形态）。
- **现状 [已备]**：三个 secret 已于 2026-07-26 注入 `appidge-api-production`（`preflight production --remote` 三个名字全在）。
  ⚠️ 注入时 Worker 尚不存在，wrangler 会问 *"There doesn't seem to be a Worker called …, create it?"* → 答 yes；
  **先建 worker 放 secret、再 deploy**，比先部署一个读不到 key 的 API 上线安全。因此管道形式
  （`openssl rand | wrangler secret put`）必须放在交互式那两条之后，否则非交互下会被该提示卡住。
- `LICENSE_HMAC_PEPPER` 不依赖 Creem，自生成即可（本次用 `openssl rand -hex 32`）。**一经上线不轮换**。
- `preflight production --remote` 会（登录后）核对这三个 secret 名是否存在，缺失逐项列出。secret **值**永不被读取/打印。
- **key 是否真的可用，healthz 证明不了**——它不碰 Creem。用 §11 的 live 探针验证。

## 5. Creem live 非秘密标识（2026-07-26 已回填）

Creem 是 Merchant of Record，**不需要 Polar 式的 org/benefit ID**——live 只需下面两个非秘密标识 + §4 三个 secret。

| 项 | 值 | 填在哪（tracked） | 校验 |
|---|---|---|---|
| Creem live **product id** | `prod_3DHsihYJeOAhNDOT0Wo0LV` | `apps/api/wrangler.toml` → `[env.production.vars]` → `CREEM_PRODUCT_ID` | 非空非占位（preflight） |
| Creem live **支付链接** | `https://www.creem.io/payment/prod_3DHsihYJeOAhNDOT0Wo0LV` | `ops/environments/production.conf` → `PUBLIC_POLAR_CHECKOUT_URL` | host `creem.io` 且不含 `/test/`（preflight）；`deploy-web` 另断言产物含此 host |

两处的 product id 必须相同——`webhook` 的 product 白名单按 `CREEM_PRODUCT_ID` 过滤，
官网 CTA 按支付链接引流；不一致会出现「买了但事件被忽略」。
回填后 `appidge-ops preflight production` 本地 **0 fail**（见 §9）。

## 6. Webhook（live）

- **[已配置，待端到端验证]**：2026-07-26 用户已在 Creem Dashboard（live）建好 webhook，指向
  `https://api.appidge.com/v1/webhooks/creem`（路径是 `/creem`，不是历史 `/polar`）。
  该域名此刻还没有 Worker，投递必然失败——`deploy-api production` 上线后再在 Dashboard 重投一条测试事件确认。
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
> ⚠️ **首发的 build 号单调性死锁（2026-07-26 实测）**：第 4 步 `build-macos production` 会拉取
> **两个** feed 求历史最高 build，production 下任一 feed 查不到即 `ops_die`（staging 是 warn 放行）。
> 而 `updates.appidge.com` 的 appcast 要到第 6 步 `publish-updates` 才存在 ⇒ 首发时第 4 步必然失败。
> 当前两 feed 最高 build = **78**（staging），故首个 production build 号须 ≥ **79**。
> 解法二选一：给 production 首发加一次性显式开关（如 `APPIDGE_ALLOW_MISSING_FEED=YES`，仍强制
> 另一 feed 的单调性），或先人工把一份合法 appcast 发上 `updates.appidge.com` 再跑发布链。
> **不要**把该检查改成静默跳过——它是防「发了个比线上更旧的 build，用户永远收不到更新」的唯一护栏。
>
> **build-macos 需受控 release Mac** 的 `.env` 签名/公证凭证 + `Config/Signing.xcconfig`；CI/开发机不具备，属人工闸门。
> **系统扩展升级**：staging→prod 共用 Bundle ID/App Group/扩展 ID，旧版→新版真机 Sparkle + 系统扩展重绑
> smoke 仍是人工闸门（`scripts/verify-staging-update.sh`）。

---

## 9. preflight / test 现状（2026-07-26 核对）

- `sh ops/tests/test-config.sh` → **PASS=95 FAIL=0**（需先 `pnpm install --frozen-lockfile`，否则 node_modules 缺失单项失败为环境问题）。
- `appidge-ops preflight production` → **OK（0 项 PREFLIGHT-FAIL）**：§5 两处回填后本地校验全过。
- 占位 fail-closed 的回归覆盖不再依赖真实 conf 里存在占位——改由 `test-config.sh` 的 fixture
  （临时 conf 塞回 `REQUIRED_`）长期守住；同时把「是否有占位」的判定收紧到赋值行，
  避免注释里解释闸门语义的 `REQUIRED_*` 字样把已回填的配置误判成未填。

## 10. 剩余人工闸门总表（上线前必须逐项完成）

1. ~~Creem KYC → live 产品 → 回填 §5 两处~~ **已完成（2026-07-26）**。
2. ~~Creem Dashboard 配 live webhook~~ **已建（2026-07-26）**，待 API 上线后重投一条事件验证（§6）。
3. ~~确认 `appidge.com` zone 在本账号~~ **已确认（2026-07-25，NS 指向 Cloudflare）**。
4. ~~注入 3 个 Worker secret（§4）~~ **已完成（2026-07-26）**，且 live key 已验证可用（§11）。
5. **[发布链]** `deploy-api` 内置 6×8s healthz 重试**不足以覆盖首次建域**——2026-07-26 实测踩空并以
   ERROR 退出，但 Worker 已部署成功（§1）。**该失败不是回滚信号**，改用连续探测判定。
6. **[发布链]** 首发的 build 号单调性死锁：`build-macos production` 要求 `updates.appidge.com`
   的 appcast 可查，而该 feed 要到 `publish-updates` 才存在（§8 脚注）。
7. **[用户]** staging 全链路 smoke 通过（买单→activate→validate→退款+disable→validate=revoked）+ production 发布审批。
8. **[release Mac]** `build-macos` 签名/公证凭证 + 真机系统扩展升级 smoke（§8）。
9. 全部就绪后按 §8 三重保护序列发布，`smoke production` 收尾。

---

## 11. 云端上线记录（2026-07-26，API + Web）

本轮范围**只有云端 API 与 Web**；macOS 出包与 `publish-updates` 未做，故 `updates.appidge.com` 仍未上线。

| 组件 | 结果 | 证据 |
|---|---|---|
| `appidge-api-production` | ✅ 上线 | Version `eebd650b-041a-400c-b211-d7ce0d27a1cf`；route `api.appidge.com`（custom domain） |
| `appidge-web-production` | ✅ 上线 | Version `b52481cb-ece9-4fec-87c4-f66e25811f42`；route `appidge.com` + `www.appidge.com`；31 静态资源 |
| D1 `appidge-licensing-production` | ✅ 无 pending | `No migrations to apply!`（0001/0002/0003 早已 apply） |
| 3 个 Worker secret | ✅ 齐 | `preflight production --remote` 0 fail |
| `updates.appidge.com` | ⛔ 未部署 | 本轮范围外；`smoke production` 的 3 条 updates 失败均源于此 |

**发布前本地闸门**（`appidge-ops test production`，EXIT=0，4/4 全跑通）：
`test-config.sh` PASS=99 FAIL=0 · `pnpm check` 绿 · `pnpm check:swift` 五包绿 ·
`wrangler dry-run` 绑定确认为 production D1 + `MOCK_MODE=false` + live product id。

**上线后验证**：

```text
appidge.com / www.appidge.com   连续 10×200
api.appidge.com/healthz         连续 10× {"status":"ok","mockMode":false}
smoke production                web 5/5 ✅  api 2/2 ✅  updates 0/3 ⛔（范围外）
```

**live key 探针**（只读，不写任何真实 license）：

```sh
curl -sS -X POST https://api.appidge.com/v1/licenses/validate \
  -H 'content-type: application/json' \
  -d '{"licenseKey":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","instanceId":"preflight-probe","appVersion":"0.0.0"}'
# → 402 {"error":"invalid_license"}
```

返回 `invalid_license` 而**不是** `upstream_unavailable`，说明 Worker 已用 live key 通过 Creem 认证、
Creem 回答"无此 license" ⇒ `CREEM_API_KEY` 确实可用。**这是 healthz 给不了的证据**（healthz 不碰 Creem）。
另：`{"licenseKey":"x"}` → 400 `invalid_request`，本地校验拦在打上游之前。

**本轮修掉的两个 ops bug**（都属"闸门静默失效"，见 commit `9033860` / `4aaaaa3`）：

1. `cmd_test` 里 `"$OPS_CONF）"` 被 sh 把全角括号并进变量名，`set -u` 下每次都崩在 2/4 步 ⇒
   **`pnpm check` / `check:swift` / dry-run 三步从来没跑过**，而且看起来像"测完了"。
2. `deploy-web` 的环境交叉检查 `grep -RFq "$bad"` 缺 `-e`，`-staging.appidge.com` 被当选项解析、
   打 usage 返回非零 ⇒ 该条静默放行（靠后一条子串模式侥幸兜住）。

**已知缺口（本轮遗留）**：官网下载 CTA 指向 `updates.appidge.com/appidge-latest.dmg`，
该域名尚无 Worker ⇒ **下载链接当前是坏的**（购买 CTA 走 Creem live，不受影响）。
关闭窗口的唯一办法是跑完 `build-macos` → `prepare-updates` → `publish-updates`（首个 build 号须 ≥ 79，
并需先解掉 §8 的单调性死锁）。

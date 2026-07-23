#!/usr/bin/env bash
# scripts/smoke-license-mock.sh — Agent F / Integration-QA
#
# 端到端 MOCK 冒烟：在本地 `wrangler dev`(MOCK_MODE) 上把 license facade 全流程跑一遍，
# 断言契约形状的响应，并验证「本地 revoked 优先于上游 active」与 webhook 验签闸门。
#
# 覆盖（CLAUDE.md §5.3 / §5.4 / §6 Worker 必测的可执行冒烟版）：
#   1. GET  /healthz                         → 200 {status:ok, mockMode:true}
#   2. POST /v1/licenses/activate            → 200 LicenseState(active)，取 instanceId
#   3. POST /v1/licenses/validate (退款前)   → 200 status=active
#   4. POST /v1/webhooks/polar  benefit_grant.revoked(Standard Webhooks 签名) → 200 {received:true}
#   5. POST /v1/licenses/validate (退款后)   → 200 status=revoked（本地 deny 覆盖上游 active）
#   6. POST /v1/webhooks/polar  篡改签名     → 401（拒绝）
#   7. POST /v1/webhooks/polar  无签名头     → 401（拒绝）
#   8. POST /v1/licenses/deactivate          → 200 {status:deactivated}
#
# 无真实 secret：全程用 apps/api/.dev.vars 的 MOCK 值（webhook 用同一 POLAR_WEBHOOK_SECRET 签名，
# 复刻 worker 的 Standard Webhooks 签名与 secret 解码逻辑）。
# 不触真实 Polar / 生产 / 网络。可重复运行（每次用唯一 license，独立临时 D1 持久化目录）。
# 若缺少 wrangler / node / jq / curl，则跳过（exit 0）并说明，不算失败。
set -u

# ── 路径 ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
API_DIR="$ROOT/apps/api"
WRANGLER="$API_DIR/node_modules/.bin/wrangler"

log()  { printf '%s\n' "$*"; }
skip() { log "SKIP: $*"; exit 0; }
die()  { log "ERROR: $*"; exit 1; }

# ── 依赖检查（缺失即跳过，不算失败）────────────────────────────────────────
command -v node >/dev/null 2>&1 || skip "node 不可用"
command -v curl >/dev/null 2>&1 || skip "curl 不可用"
command -v jq   >/dev/null 2>&1 || skip "jq 不可用（用于断言 JSON 字段）"
[ -x "$WRANGLER" ] || skip "wrangler 未安装（apps/api/node_modules/.bin/wrangler 缺失，先 pnpm install）"

# ── .dev.vars（缺则从 example 复制；不覆盖已有）────────────────────────────
CREATED_DEV_VARS=0
if [ ! -f "$API_DIR/.dev.vars" ]; then
  [ -f "$API_DIR/.dev.vars.example" ] || die ".dev.vars 与 .dev.vars.example 都不存在"
  cp "$API_DIR/.dev.vars.example" "$API_DIR/.dev.vars"
  CREATED_DEV_VARS=1
  log "· 已从 .dev.vars.example 复制出 .dev.vars（MOCK 占位值）"
fi

# 从 .dev.vars 解析 worker 运行时会用到的值（dev 时 .dev.vars 覆盖 wrangler.toml [vars]）。
readvar() { grep -E "^$1=" "$API_DIR/.dev.vars" | head -1 | cut -d= -f2- | tr -d '"'; }
SECRET="$(readvar POLAR_WEBHOOK_SECRET)"
BENEFIT="$(readvar POLAR_BENEFIT_ID)"
[ -n "$SECRET" ]  || die ".dev.vars 缺少 POLAR_WEBHOOK_SECRET"
[ -n "$BENEFIT" ] || die ".dev.vars 缺少 POLAR_BENEFIT_ID"

# ── 运行期变量 ──────────────────────────────────────────────────────────────
RUNID="$(date +%s)-$$"
LICENSE="MOCK-LICENSE-SMOKE-$RUNID"          # kindOf() → active
PORT="${APPIDGE_SMOKE_PORT:-8798}"
PERSIST="$(mktemp -d "${TMPDIR:-/tmp}/appidge-smoke.XXXXXX")"
DEVLOG="$PERSIST/wrangler-dev.log"
BASE="http://127.0.0.1:$PORT"
WRANGLER_PID=""

FAIL=0
pass() { log "  PASS  $*"; }
fail() { log "  FAIL  $*"; FAIL=$((FAIL+1)); }

# ── 清理 ────────────────────────────────────────────────────────────────────
kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child"; done
  kill "$pid" 2>/dev/null
}
cleanup() {
  if [ -n "$WRANGLER_PID" ]; then kill_tree "$WRANGLER_PID"; fi
  # 兜底：清掉可能残留、绑定本次持久化目录的 workerd
  pkill -f "persist-to $PERSIST" 2>/dev/null
  rm -rf "$PERSIST" 2>/dev/null
  if [ "$CREATED_DEV_VARS" = "1" ]; then rm -f "$API_DIR/.dev.vars"; fi
}
trap cleanup EXIT INT TERM

log "=== Appidge MOCK license 冒烟 ==="
log "· license=$LICENSE  benefit=$BENEFIT  port=$PORT"
log "· persist=$PERSIST"

# ── 建表（本地 D1 迁移到本次持久化目录）─────────────────────────────────────
( cd "$API_DIR" && "$WRANGLER" d1 migrations apply appidge-licensing --local --persist-to "$PERSIST" ) \
  < /dev/null > "$PERSIST/migrate.log" 2>&1 \
  || { tail -20 "$PERSIST/migrate.log"; die "D1 迁移失败"; }
log "· D1 迁移完成（0001_init.sql + 0002_polar.sql）"

# ── 启动 wrangler dev（后台）────────────────────────────────────────────────
( cd "$API_DIR" && exec "$WRANGLER" dev --ip 127.0.0.1 --port "$PORT" --persist-to "$PERSIST" ) \
  < /dev/null > "$DEVLOG" 2>&1 &
WRANGLER_PID=$!
log "· wrangler dev 启动中 (pid=$WRANGLER_PID)…"

# ── 等待就绪（轮询 healthz，最多 ~90s）──────────────────────────────────────
READY=0
for _ in $(seq 1 90); do
  if ! kill -0 "$WRANGLER_PID" 2>/dev/null; then
    tail -30 "$DEVLOG"; die "wrangler dev 进程提前退出"
  fi
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/healthz" 2>/dev/null || true)"
  if [ "$CODE" = "200" ]; then READY=1; break; fi
  sleep 1
done
[ "$READY" = "1" ] || { tail -30 "$DEVLOG"; die "wrangler dev 90s 内未就绪"; }

# ── HTTP 辅助：把 body 与状态码用换行分隔返回 ────────────────────────────────
post_json() { curl -sS -X POST "$BASE$1" -H 'content-type: application/json' --data "$2" -w $'\n%{http_code}'; }
split_code() { printf '%s' "$1" | tail -1; }
split_body() { printf '%s' "$1" | sed '$d'; }

# 断言 JSON 字段等值
assert_field() { # label json jqexpr expected
  local got; got="$(printf '%s' "$2" | jq -r "$3" 2>/dev/null)"
  if [ "$got" = "$4" ]; then pass "$1 ($3=$got)"; else fail "$1 期望 $3=$4，实得 '$got'"; fi
}
assert_code() { # label actual expected
  if [ "$2" = "$3" ]; then pass "$1 (HTTP $2)"; else fail "$1 期望 HTTP $3，实得 $2"; fi
}

# ── 1. healthz ──────────────────────────────────────────────────────────────
HZ="$(curl -sS "$BASE/healthz")"
assert_field "healthz status" "$HZ" '.status' 'ok'
assert_field "healthz mockMode" "$HZ" '.mockMode' 'true'

# ── 2. activate ─────────────────────────────────────────────────────────────
R="$(post_json /v1/licenses/activate "$(printf '{"licenseKey":"%s","instanceName":"appidge-smoke","appVersion":"1.0.0"}' "$LICENSE")")"
C="$(split_code "$R")"; B="$(split_body "$R")"
assert_code  "activate 状态码" "$C" 200
assert_field "activate.status" "$B" '.status' 'active'
assert_field "activate.activationLimit" "$B" '.activationLimit' '3'
INSTANCE="$(printf '%s' "$B" | jq -r '.instanceId')"
if [ -n "$INSTANCE" ] && [ "$INSTANCE" != "null" ]; then pass "activate.instanceId=$INSTANCE"; else fail "activate 未返回 instanceId"; INSTANCE="inst_MOCK_0000000000"; fi
VAT="$(printf '%s' "$B" | jq -r '.validatedAt')"
if [ -n "$VAT" ] && [ "$VAT" != "null" ]; then pass "activate.validatedAt=$VAT"; else fail "activate 缺少 validatedAt"; fi

# ── 3. validate（退款前，应 active）─────────────────────────────────────────
R="$(post_json /v1/licenses/validate "$(printf '{"licenseKey":"%s","instanceId":"%s","appVersion":"1.0.0"}' "$LICENSE" "$INSTANCE")")"
C="$(split_code "$R")"; B="$(split_body "$R")"
assert_code  "validate(退款前) 状态码" "$C" 200
assert_field "validate(退款前).status" "$B" '.status' 'active'

# ── 4. benefit_grant.revoked webhook（Standard Webhooks 正确签名）────────────
# license_key_id 必须与 MOCK client 为该 license 计算的值一致，才能命中 activate 时
# 惰性登记的 fingerprint↔license_key_id 映射行 → validate 本地-优先返回 revoked。
LK_ID="$(node -e 'let h=0;const k=process.argv[1];for(let i=0;i<k.length;i++)h=(h*31+k.charCodeAt(i))>>>0;process.stdout.write("lk_MOCK_"+h.toString(16).padStart(8,"0"))' "$LICENSE")"
REVOKE_FILE="$PERSIST/revoke.json"
printf '{"type":"benefit_grant.revoked","timestamp":"2026-07-22T00:00:00Z","data":{"id":"bg_smoke_%s","order_id":"ord_smoke_%s","customer_id":"cust_smoke","benefit_id":"%s","is_revoked":true,"properties":{"license_key_id":"%s","display_key":"XXXX-1234"}}}' \
  "$RUNID" "$RUNID" "$BENEFIT" "$LK_ID" > "$REVOKE_FILE"

WID="msg_smoke_$RUNID"
WTS="$(date +%s)"
# 复刻 worker crypto.ts：decodeWebhookSecret(whsec_ 前缀→base64，失败退化 utf8) + Standard Webhooks 签名。
sign_wh() { # file id ts secret → "v1,<base64sig>"
  node -e '
    const c=require("crypto"),fs=require("fs");
    const [file,id,ts,secret]=process.argv.slice(1);
    function decodeSecret(s){const raw=s.startsWith("whsec_")?s.slice(6):s;
      try{const bin=atob(raw);const b=Buffer.alloc(bin.length);for(let i=0;i<bin.length;i++)b[i]=bin.charCodeAt(i);return b;}
      catch{return Buffer.from(raw,"utf8");}}
    const body=fs.readFileSync(file);
    const signed=Buffer.concat([Buffer.from(id+"."+ts+".","utf8"),body]);
    process.stdout.write("v1,"+c.createHmac("sha256",decodeSecret(secret)).update(signed).digest("base64"));
  ' "$1" "$2" "$3" "$4"
}
SIG="$(sign_wh "$REVOKE_FILE" "$WID" "$WTS" "$SECRET")"
R="$(curl -sS -X POST "$BASE/v1/webhooks/polar" -H 'content-type: application/json' -H "webhook-id: $WID" -H "webhook-timestamp: $WTS" -H "webhook-signature: $SIG" --data-binary @"$REVOKE_FILE" -w $'\n%{http_code}')"
C="$(split_code "$R")"; B="$(split_body "$R")"
assert_code  "revoke webhook(签名) 状态码" "$C" 200
assert_field "revoke webhook.received" "$B" '.received' 'true'

# ── 5. validate（退款后，本地 revoked 覆盖上游 active）───────────────────────
R="$(post_json /v1/licenses/validate "$(printf '{"licenseKey":"%s","instanceId":"%s","appVersion":"1.0.0"}' "$LICENSE" "$INSTANCE")")"
C="$(split_code "$R")"; B="$(split_body "$R")"
assert_code  "validate(退款后) 状态码" "$C" 200
assert_field "validate(退款后).status[本地 revoked 优先]" "$B" '.status' 'revoked'

# ── 6. 篡改签名 → 401 ───────────────────────────────────────────────────────
BADSIG="${SIG%?}$([ "${SIG: -1}" = "A" ] && echo B || echo A)"
C="$(curl -sS -o /dev/null -X POST "$BASE/v1/webhooks/polar" -H 'content-type: application/json' -H "webhook-id: $WID" -H "webhook-timestamp: $WTS" -H "webhook-signature: $BADSIG" --data-binary @"$REVOKE_FILE" -w '%{http_code}')"
assert_code "篡改签名 webhook 被拒" "$C" 401

# ── 7. 无签名头 → 401 ───────────────────────────────────────────────────────
C="$(curl -sS -o /dev/null -X POST "$BASE/v1/webhooks/polar" -H 'content-type: application/json' --data-binary @"$REVOKE_FILE" -w '%{http_code}')"
assert_code "无签名 webhook 被拒" "$C" 401

# ── 8. deactivate ───────────────────────────────────────────────────────────
R="$(post_json /v1/licenses/deactivate "$(printf '{"licenseKey":"%s","instanceId":"%s"}' "$LICENSE" "$INSTANCE")")"
C="$(split_code "$R")"; B="$(split_body "$R")"
assert_code  "deactivate 状态码" "$C" 200
assert_field "deactivate.status" "$B" '.status' 'deactivated'

# ── 汇总 ────────────────────────────────────────────────────────────────────
log "=== 结果 ==="
if [ "$FAIL" -eq 0 ]; then
  log "ALL PASS — MOCK license 端到端冒烟通过（activate→validate→refund→revoked→deactivate + 验签闸门）"
  exit 0
else
  log "FAILED — $FAIL 项断言未通过（见上）"
  exit 1
fi

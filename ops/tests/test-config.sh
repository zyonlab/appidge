#!/bin/sh
# ops/tests/test-config.sh —— 环境矩阵与安全保护的无网络测试。
#
# 两类断言（docs/claude-code-staging-production-free-plan.md Phase 0）：
#   [structure] 仓库结构：staging/prod 拓扑不冲突、脚本无副作用/绝对路径、ops CLI 存在且
#               保护逻辑生效——实现完成后必须全绿。
#   [gate]      真实 production 资源（Polar IDs / D1 ID / live checkout）缺失时，
#               preflight 必须 fail closed 并列出全部缺失项；用户填入真实值后自动转为
#               「preflight 通过」断言。本测试不要求真实值存在。
#
# 无网络、无 secret、不写远端。可在 macOS /bin/sh 与 Ubuntu dash 下运行。
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"

PASS=0
FAIL=0
FAILED_LIST=""

t_pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
t_fail() {
  FAIL=$((FAIL + 1))
  FAILED_LIST="${FAILED_LIST}  FAIL $1
"
  printf 'FAIL %s\n' "$1"
}

# expect_ok "描述" cmd...   —— 命令退出 0 则通过
expect_ok() {
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then t_pass "$desc"; else t_fail "$desc"; fi
}

# expect_fail "描述" cmd... —— 命令退出非 0 则通过
expect_fail() {
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then t_fail "${desc}（预期失败但成功了）"; else t_pass "$desc"; fi
}

# 从 wrangler jsonc/toml 中提取某 env 的第一个 route pattern
jsonc_env_pattern() { # $1=file $2=envname
  awk -v env="\"$2\"" '
    index($0, env ":") { f = 1 }
    f && /"pattern"/ {
      line = $0
      sub(/.*"pattern"[^"]*"/, "", line)
      sub(/".*/, "", line)
      print line
      exit
    }' "$1"
}

toml_prod_section() { awk '/^\[env\.production/ { f = 1 } f' apps/api/wrangler.toml; }

echo "== ops/tests/test-config.sh =="
echo "repo: $ROOT"
echo

# ---------------------------------------------------------------------------
# 1. [structure] updates 拓扑：staging/prod 不得共用同一 hostname
# ---------------------------------------------------------------------------
UPD=infra/updates/wrangler.jsonc
UPD_STG=$(jsonc_env_pattern "$UPD" staging)
UPD_PRD=$(jsonc_env_pattern "$UPD" production)

[ "$UPD_STG" = "updates-staging.appidge.com" ] \
  && t_pass "updates staging route = updates-staging.appidge.com" \
  || t_fail "updates staging route = updates-staging.appidge.com（实际：${UPD_STG:-空}）"
[ "$UPD_PRD" = "updates.appidge.com" ] \
  && t_pass "updates production route = updates.appidge.com" \
  || t_fail "updates production route = updates.appidge.com（实际：${UPD_PRD:-空}）"
[ -n "$UPD_STG" ] && [ "$UPD_STG" != "$UPD_PRD" ] \
  && t_pass "updates staging/production hostname 不重复" \
  || t_fail "updates staging/production hostname 不重复"

# ---------------------------------------------------------------------------
# 2. [structure] API production route 与 D1 名称
# ---------------------------------------------------------------------------
toml_prod_section | grep -q 'pattern *= *"api\.appidge\.com"' \
  && t_pass "api wrangler.toml 有 production route api.appidge.com" \
  || t_fail "api wrangler.toml 有 production route api.appidge.com"
toml_prod_section | grep -q 'custom_domain *= *true' \
  && t_pass "api production route 是 custom_domain" \
  || t_fail "api production route 是 custom_domain"
toml_prod_section | grep -q 'database_name *= *"appidge-licensing-production"' \
  && t_pass "api production D1 名称 = appidge-licensing-production" \
  || t_fail "api production D1 名称 = appidge-licensing-production"

# web routes（不改域名，只固化现状防回归）
WEB_STG=$(jsonc_env_pattern apps/web/wrangler.jsonc staging)
[ "$WEB_STG" = "staging.appidge.com" ] \
  && t_pass "web staging route = staging.appidge.com" \
  || t_fail "web staging route = staging.appidge.com（实际：${WEB_STG:-空}）"

# ---------------------------------------------------------------------------
# 3. [structure] 发布脚本卫生：无个人绝对路径、无 AppConfig 重写、无 pbxproj 自增
# ---------------------------------------------------------------------------
REL_SCRIPTS="scripts/release-staging.sh scripts/finish-release-staging.sh scripts/verify-staging-update.sh scripts/archive-and-notarize.sh"
expect_fail "发布脚本不含 /Users/admin 个人绝对路径" \
  grep -l '/Users/admin' $REL_SCRIPTS
expect_fail "release 脚本不再重写 Config/AppConfig.xcconfig" \
  grep -E 'cat > .*AppConfig\.xcconfig' scripts/release-staging.sh scripts/finish-release-staging.sh
expect_fail "archive 脚本不再 sed -i 自增 CURRENT_PROJECT_VERSION" \
  grep -E 'sed -i.*CURRENT_PROJECT_VERSION' scripts/archive-and-notarize.sh
expect_ok "archive 脚本要求 APPIDGE_BUILD_NUMBER" \
  grep -q 'APPIDGE_BUILD_NUMBER' scripts/archive-and-notarize.sh
expect_ok "archive 脚本显式注入 SPARKLE_FEED_URL" \
  grep -q 'SPARKLE_FEED_URL' scripts/archive-and-notarize.sh
expect_ok "archive 脚本显式传 CURRENT_PROJECT_VERSION 给 xcodebuild" \
  grep -q 'CURRENT_PROJECT_VERSION=' scripts/archive-and-notarize.sh
expect_fail "verify-staging-update.sh 默认 feed 不再是 production updates 域" \
  grep -E 'FEED="?https://updates\.appidge\.com' scripts/verify-staging-update.sh

# 兼容 wrapper：必须已改造为指向 ops/bin/appidge-ops 的 wrapper，且无参数运行只显示
# 用法并退出非零（防误发布）。⚠️ 安全约束：旧版脚本是全量发布脚本（写配置/签名/部署），
# 绝不能在测试里执行——只有确认是 wrapper（含 appidge-ops 引用）后才实际运行。
for w in scripts/release-staging.sh scripts/finish-release-staging.sh; do
  if grep -q 'appidge-ops' "$w" 2>/dev/null; then
    t_pass "$w 已是 appidge-ops 兼容 wrapper"
    expect_fail "$w 无参数运行退出非零（wrapper 用法提示）" sh "$w"
  else
    t_fail "$w 已是 appidge-ops 兼容 wrapper（未改造，跳过执行以防误发布）"
  fi
done

# ---------------------------------------------------------------------------
# 4. [structure] ops 目录：conf / lib / CLI 存在且语法正确
# ---------------------------------------------------------------------------
for f in ops/environments/staging.conf ops/environments/production.conf \
         ops/lib/common.sh ops/bin/appidge-ops; do
  [ -f "$f" ] && t_pass "存在 $f" || t_fail "存在 $f"
done
for f in ops/lib/common.sh ops/bin/appidge-ops $REL_SCRIPTS; do
  [ -f "$f" ] || continue
  expect_ok "sh -n $f" sh -n "$f"
done

# ---------------------------------------------------------------------------
# 5. [structure] 环境配置契约：allowlist keys、环境匹配、URL 规则
# ---------------------------------------------------------------------------
ALLOW_KEYS='APPIDGE_ENVIRONMENT PUBLIC_SITE_URL PUBLIC_POLAR_CHECKOUT_URL PUBLIC_API_BASE_URL PUBLIC_DOWNLOAD_URL LICENSE_API_BASE_URL LICENSE_CHECKOUT_URL SPARKLE_FEED_URL API_D1_DATABASE_NAME'

conf_keys() { grep -E '^[A-Z_]+=' "$1" | cut -d= -f1; }
conf_get() { # $1=file $2=key —— 在纯净子 shell 里 source 后取值
  sh -c "set -eu; . '$1'; printf '%s' \"\${$2:-}\"" 2>/dev/null
}

for env in staging production; do
  conf="ops/environments/$env.conf"
  [ -f "$conf" ] || continue

  expect_ok "$conf 可被 POSIX sh source" sh -c ". '$conf'"

  extra=""
  for k in $(conf_keys "$conf"); do
    case " $ALLOW_KEYS " in
      *" $k "*) ;;
      *) extra="$extra $k" ;;
    esac
  done
  [ -z "$extra" ] && t_pass "$conf 只含 allowlist keys" \
    || t_fail "$conf 只含 allowlist keys（多出：${extra}）"

  missing=""
  for k in $ALLOW_KEYS; do
    grep -q "^$k=" "$conf" || missing="$missing $k"
  done
  [ -z "$missing" ] && t_pass "$conf 含全部 allowlist keys" \
    || t_fail "$conf 含全部 allowlist keys（缺：${missing}）"

  [ "$(conf_get "$conf" APPIDGE_ENVIRONMENT)" = "$env" ] \
    && t_pass "$conf APPIDGE_ENVIRONMENT=$env" \
    || t_fail "$conf APPIDGE_ENVIRONMENT=$env"

  # 所有 URL 必须 HTTPS（REQUIRED_* 占位除外——由 preflight 拦截）
  bad_url=""
  for k in PUBLIC_SITE_URL PUBLIC_POLAR_CHECKOUT_URL PUBLIC_API_BASE_URL \
           PUBLIC_DOWNLOAD_URL LICENSE_API_BASE_URL LICENSE_CHECKOUT_URL SPARKLE_FEED_URL; do
    v=$(conf_get "$conf" "$k")
    case "$v" in
      REQUIRED_*|'') ;;               # 占位/缺失交给 preflight 处理
      https://*) ;;
      *) bad_url="$bad_url $k" ;;
    esac
  done
  [ -z "$bad_url" ] && t_pass "$conf 所有 URL 均为 HTTPS 或 REQUIRED_ 占位" \
    || t_fail "$conf 所有 URL 均为 HTTPS 或 REQUIRED_ 占位（违规：${bad_url}）"
done

# staging conf 专项：appidge 域 URL 必须落在 staging hostname
SC=ops/environments/staging.conf
if [ -f "$SC" ]; then
  case "$(conf_get "$SC" PUBLIC_SITE_URL)" in
    https://staging.appidge.com*) t_pass "staging PUBLIC_SITE_URL 用 staging.appidge.com" ;;
    *) t_fail "staging PUBLIC_SITE_URL 用 staging.appidge.com" ;;
  esac
  case "$(conf_get "$SC" LICENSE_API_BASE_URL)" in
    https://api-staging.appidge.com*) t_pass "staging LICENSE_API_BASE_URL 用 api-staging" ;;
    *) t_fail "staging LICENSE_API_BASE_URL 用 api-staging" ;;
  esac
  case "$(conf_get "$SC" SPARKLE_FEED_URL)" in
    https://updates-staging.appidge.com/*) t_pass "staging SPARKLE_FEED_URL 用 updates-staging" ;;
    *) t_fail "staging SPARKLE_FEED_URL 用 updates-staging" ;;
  esac
  [ "$(conf_get "$SC" API_D1_DATABASE_NAME)" = "appidge-licensing-staging" ] \
    && t_pass "staging D1 名称 = appidge-licensing-staging" \
    || t_fail "staging D1 名称 = appidge-licensing-staging"
fi

# production conf 专项：不得包含 staging/sandbox/localhost/.invalid/PLACEHOLDER
PC=ops/environments/production.conf
if [ -f "$PC" ]; then
  bad=""
  for k in PUBLIC_SITE_URL PUBLIC_API_BASE_URL PUBLIC_DOWNLOAD_URL \
           LICENSE_API_BASE_URL LICENSE_CHECKOUT_URL SPARKLE_FEED_URL; do
    v=$(conf_get "$PC" "$k")
    case "$v" in
      *staging*|*sandbox*|*localhost*|*.invalid*|*PLACEHOLDER*) bad="$bad $k" ;;
    esac
  done
  [ -z "$bad" ] && t_pass "production conf 无 staging/sandbox/localhost/.invalid/PLACEHOLDER" \
    || t_fail "production conf 无 staging/sandbox/localhost/.invalid/PLACEHOLDER（违规：${bad}）"
  [ "$(conf_get "$PC" API_D1_DATABASE_NAME)" = "appidge-licensing-production" ] \
    && t_pass "production D1 名称 = appidge-licensing-production" \
    || t_fail "production D1 名称 = appidge-licensing-production"
fi

# conf 不得包含 secret 形态的值（token/secret/pepper 关键字）
expect_fail "ops/environments 不含 secret 形态键值" \
  grep -riE '(access_token|webhook_secret|hmac_pepper|api_key|polar_oat_|whsec_)' ops/environments

# ---------------------------------------------------------------------------
# 6. [structure] CLI 行为与安全保护（存在 CLI 才测）
# ---------------------------------------------------------------------------
CLI=ops/bin/appidge-ops
if [ -x "$CLI" ]; then
  expect_fail "appidge-ops 无参数退出非零" "$CLI"
  expect_fail "appidge-ops 未知环境退出非零" "$CLI" show-config nosuchenv
  expect_ok  "appidge-ops show-config staging" "$CLI" show-config staging

  # production 三重保护：guard 必须在任何远端/耗时操作之前 fail closed
  out=$("$CLI" deploy-api production --apply 2>&1); rc=$?
  if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'confirm-production'; then
    t_pass "production --apply 缺 --confirm-production 被拒"
  else
    t_fail "production --apply 缺 --confirm-production 被拒"
  fi
  out=$("$CLI" deploy-api production --apply --confirm-production 2>&1); rc=$?
  if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'APPIDGE_PRODUCTION_APPROVED'; then
    t_pass "production 缺 APPIDGE_PRODUCTION_APPROVED=YES 被拒"
  else
    t_fail "production 缺 APPIDGE_PRODUCTION_APPROVED=YES 被拒"
  fi
  out=$(APPIDGE_PRODUCTION_APPROVED=NO "$CLI" migrate-api production --apply --confirm-production 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    t_pass "APPIDGE_PRODUCTION_APPROVED=NO 仍被拒（必须精确 =YES）"
  else
    t_fail "APPIDGE_PRODUCTION_APPROVED=NO 仍被拒（必须精确 =YES）"
  fi

  # plan 是只读的：不得改动 tracked 文件
  before=$(git status --porcelain)
  "$CLI" plan staging >/dev/null 2>&1
  after=$(git status --porcelain)
  [ "$before" = "$after" ] && t_pass "plan staging 不改动工作区" || t_fail "plan staging 不改动工作区"

  # ------------------------------------------------------------------
  # [gate] production preflight：占位存在 ⇒ 必须 fail closed 且逐项列出；
  #        真实值填入后 ⇒ 本地 preflight 必须通过（结构不阻塞）。
  # ------------------------------------------------------------------
  has_placeholder=0
  toml_prod_section | grep -qE 'PLACEHOLDER|00000000-0000-0000-0000-000000000000' && has_placeholder=1
  grep -q 'REQUIRED_' "$PC" 2>/dev/null && has_placeholder=1

  pf_out=$("$CLI" preflight production 2>&1); pf_rc=$?
  if [ "$has_placeholder" = 1 ]; then
    if [ $pf_rc -ne 0 ]; then
      t_pass "production preflight 因占位 fail closed"
    else
      t_fail "production preflight 因占位 fail closed（占位存在却通过了）"
    fi
    n=$(printf '%s\n' "$pf_out" | grep -c 'PREFLIGHT-FAIL:')
    [ "$n" -ge 1 ] && t_pass "production preflight 逐项列出全部缺失（$n 项 ≥ 1）" \
      || t_fail "production preflight 逐项列出全部缺失（只有 $n 项）"
    # 只断言「仍是占位」的项被列出——真实值已回填的项（如 2026-07-24 起的 D1 id）不得再被要求缺失。
    for item in POLAR_ORGANIZATION_ID POLAR_PRODUCT_ID POLAR_BENEFIT_ID; do
      if toml_prod_section | grep -q "${item}[^_]*PLACEHOLDER"; then
        printf '%s\n' "$pf_out" | grep -q "$item" \
          && t_pass "production preflight 缺失项含 $item" \
          || t_fail "production preflight 缺失项含 $item"
      fi
    done
    if toml_prod_section | grep -q '00000000-0000-0000-0000-000000000000'; then
      printf '%s\n' "$pf_out" | grep -q 'database_id' \
        && t_pass "production preflight 缺失项含 database_id" \
        || t_fail "production preflight 缺失项含 database_id"
    fi
    if grep -q 'REQUIRED_' "$PC" 2>/dev/null; then
      printf '%s\n' "$pf_out" | grep -q 'PUBLIC_POLAR_CHECKOUT_URL' \
        && t_pass "production preflight 缺失项含 PUBLIC_POLAR_CHECKOUT_URL" \
        || t_fail "production preflight 缺失项含 PUBLIC_POLAR_CHECKOUT_URL"
    fi
  else
    [ $pf_rc -eq 0 ] && t_pass "production preflight（真实值已填）通过" \
      || t_fail "production preflight（真实值已填）通过：$pf_out"
  fi

  # staging preflight：结构必须通过；只允许因真实人工输入（checkout/远端）失败
  sf_out=$("$CLI" preflight staging 2>&1); sf_rc=$?
  if [ $sf_rc -eq 0 ]; then
    t_pass "staging preflight 本地通过"
  elif printf '%s\n' "$sf_out" | grep -q 'PREFLIGHT-FAIL:.*CHECKOUT'; then
    t_pass "staging preflight 仅因 checkout 人工输入失败（允许）"
  else
    t_fail "staging preflight 本地通过（异常失败：$(printf '%s' "$sf_out" | grep 'PREFLIGHT-FAIL:' | head -3)）"
  fi

  # ------------------------------------------------------------------
  # fixture：环境交叉/占位/.invalid 必须被拒（用临时配置目录，不碰真实 conf）
  # ------------------------------------------------------------------
  FIX=$(mktemp -d)
  mkdir -p "$FIX"
  # a) APPIDGE_ENVIRONMENT 与文件名不一致
  sed 's/^APPIDGE_ENVIRONMENT=.*/APPIDGE_ENVIRONMENT='\''production'\''/' \
    "$SC" > "$FIX/staging.conf"
  cp "$PC" "$FIX/production.conf"
  expect_fail "环境参数与 conf 内 APPIDGE_ENVIRONMENT 不一致被拒" \
    env APPIDGE_OPS_CONFIG_DIR="$FIX" "$CLI" show-config staging
  # b) .invalid checkout 在 preflight 被拒
  sed 's|^PUBLIC_POLAR_CHECKOUT_URL=.*|PUBLIC_POLAR_CHECKOUT_URL='\''https://checkout.example.invalid/x'\''|' \
    "$SC" > "$FIX/staging.conf"
  expect_fail "staging preflight 拒绝 .invalid checkout" \
    env APPIDGE_OPS_CONFIG_DIR="$FIX" "$CLI" preflight staging
  # c) staging feed 指向 production updates 域被拒（环境交叉）
  sed 's|^SPARKLE_FEED_URL=.*|SPARKLE_FEED_URL='\''https://updates.appidge.com/appcast.xml'\''|' \
    "$SC" > "$FIX/staging.conf"
  expect_fail "staging preflight 拒绝 production updates 域（环境交叉）" \
    env APPIDGE_OPS_CONFIG_DIR="$FIX" "$CLI" preflight staging
  # d) 非 allowlist key 被拒
  { cat "$SC"; echo "EVIL_KEY='x'"; } > "$FIX/staging.conf"
  expect_fail "非 allowlist key 被拒" \
    env APPIDGE_OPS_CONFIG_DIR="$FIX" "$CLI" show-config staging
  rm -rf "$FIX"

  # ------------------------------------------------------------------
  # wrangler_run 目录正确性（回归：pnpm --dir 曾把 cwd 拉回 apps/api，
  # 导致 deploy-web/updates 实际部署或 dry-run 的是 api Worker）
  # 用假 OPS_ROOT + 打印 $PWD 的 wrangler stub 验证每个目标在自己的目录执行。
  # ------------------------------------------------------------------
  WRTMP=$(mktemp -d)
  mkdir -p "$WRTMP/apps/api/node_modules/.bin" "$WRTMP/apps/web" "$WRTMP/infra/updates"
  printf '#!/bin/sh\npwd\n' > "$WRTMP/apps/api/node_modules/.bin/wrangler"
  chmod +x "$WRTMP/apps/api/node_modules/.bin/wrangler"
  wr_cwd() { # $1=target $2=期望后缀
    out=$(sh -c "OPS_ROOT='$WRTMP'; . ops/lib/common.sh; OPS_ROOT='$WRTMP'; wrangler_run $1 whoami" 2>/dev/null | tail -1)
    case "$out" in *"$2") return 0 ;; *) return 1 ;; esac
  }
  expect_ok "wrangler_run api 在 apps/api 执行"          wr_cwd api /apps/api
  expect_ok "wrangler_run web 在 apps/web 执行"          wr_cwd web /apps/web
  expect_ok "wrangler_run updates 在 infra/updates 执行" wr_cwd updates /infra/updates
  rm -rf "$WRTMP"

  # ------------------------------------------------------------------
  # 25 MiB 静态文件限制（common.sh 函数级测试）
  # ------------------------------------------------------------------
  if grep -q 'assert_static_assets_within_limit' ops/lib/common.sh 2>/dev/null; then
    TMPD=$(mktemp -d)
    dd if=/dev/zero of="$TMPD/small.bin" bs=1024 count=8 2>/dev/null
    expect_ok "25MiB 检查：8KiB 文件通过" \
      sh -c ". ops/lib/common.sh; assert_static_assets_within_limit '$TMPD'"
    dd if=/dev/zero of="$TMPD/big.bin" bs=1048576 count=26 2>/dev/null
    expect_fail "25MiB 检查：26MiB 文件被拒" \
      sh -c ". ops/lib/common.sh; assert_static_assets_within_limit '$TMPD'"
    rm -rf "$TMPD"
  else
    t_fail "common.sh 提供 assert_static_assets_within_limit（25MiB 保护）"
  fi
else
  t_fail "ops/bin/appidge-ops 存在且可执行（CLI 行为与保护测试被跳过）"
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
echo
echo "== 结果：PASS=$PASS FAIL=$FAIL =="
if [ "$FAIL" -gt 0 ]; then
  printf '%s' "$FAILED_LIST"
  exit 1
fi
exit 0

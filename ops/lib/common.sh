# ops/lib/common.sh —— appidge-ops 与 ops/tests 共用的 POSIX sh 库。
# 职责：仓库根定位、环境配置读取与 allowlist 校验、URL/环境交叉校验、Wrangler 拓扑校验、
#       production 占位检测、生产写保护、命令依赖检查、25MiB 静态资源保护。
# 纪律：不读取/打印任何 secret；所有校验失败逐项累积输出（不是只报第一个）。
# 兼容 macOS /bin/sh(bash 3.2) 与 Ubuntu dash。

# ---------------------------------------------------------------------------
# 仓库根：调用方（appidge-ops）可先设 OPS_ROOT；否则从 git 推导，再退回 cwd。
# ---------------------------------------------------------------------------
if [ -z "${OPS_ROOT:-}" ]; then
  OPS_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi

ops_note() { printf '[appidge-ops] %s\n' "$*"; }
ops_warn() { printf '[appidge-ops] WARN: %s\n' "$*" >&2; }
ops_die()  { printf '[appidge-ops] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 失败累积：fail_add 立即打印 PREFLIGHT-FAIL 行并计数；fail_flush 汇总并返回非零。
# ---------------------------------------------------------------------------
OPS_FAIL_COUNT=0
fail_add() {
  OPS_FAIL_COUNT=$((OPS_FAIL_COUNT + 1))
  printf 'PREFLIGHT-FAIL: %s\n' "$*" >&2
}
fail_reset() { OPS_FAIL_COUNT=0; }
fail_flush() {
  if [ "$OPS_FAIL_COUNT" -gt 0 ]; then
    printf '[appidge-ops] preflight 失败：共 %s 项（见上 PREFLIGHT-FAIL 列表）\n' "$OPS_FAIL_COUNT" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 占位检测：REQUIRED_* / *PLACEHOLDER* / 全零 UUID 都视为未填真实值。
# ---------------------------------------------------------------------------
is_placeholder() {
  case "$1" in
    REQUIRED_*|*PLACEHOLDER*|*00000000-0000-0000-0000-000000000000*|'') return 0 ;;
    *) return 1 ;;
  esac
}

url_host() { # 提取 https URL 的 host（不含 path/port）
  printf '%s' "$1" | sed -e 's|^[a-z]*://||' -e 's|[/:].*$||'
}

# ---------------------------------------------------------------------------
# build 号单调性：staging/production 共用一条全局递增序列，新包必须高于**两个** feed
# 出现过的最高 build——否则用户装到手的版本会比线上更旧，且永远收不到更新。
# 测试通过重定义 feed_max_build 打桩，不联网。
# ---------------------------------------------------------------------------
feed_max_build() { # $1=feed url → 输出 feed 内最大 sparkle:version；查询失败输出空
  # 兼容两种 Sparkle 写法：属性 sparkle:version="63" 与元素 <sparkle:version>63</sparkle:version>
  curl -fsS -m 20 "$1" 2>/dev/null \
    | grep -oE 'sparkle:version="[0-9]+"|<sparkle:version>[0-9]+' \
    | grep -oE '[0-9]+' | sort -n | tail -1
}

# assert_build_monotonic <env> <build number> <feed url>...
#
# 首发死锁：production 的 appcast 要到 publish-updates 才存在，而 build-macos 在它之前就要
# 求该 feed 可查 ⇒ 第一个 production 包永远出不来。放行开关 APPIDGE_ALLOW_MISSING_FEED=YES
# 只免除**查不到的那个 feed**；可查的 feed 照旧强制单调，两个都查不到时开关也不放行。
# 绝不能把这个检查改成静默跳过——它是防「发了个比线上更旧的 build」的唯一护栏。
assert_build_monotonic() {
  _abm_env=$1; _abm_build=$2; shift 2
  _abm_ok=0; _abm_missing=""
  for _abm_feed in "$@"; do
    _abm_max=$(feed_max_build "$_abm_feed" || true)
    if [ -n "${_abm_max:-}" ]; then
      _abm_ok=$((_abm_ok + 1))
      ops_note "feed $_abm_feed 最高 build：$_abm_max"
      [ "$_abm_build" -gt "$_abm_max" ] \
        || ops_die "--build-number $_abm_build 未高于 $_abm_feed 的最高历史 build ${_abm_max}（staging/prod 共用全局单调序列）"
    else
      _abm_missing="$_abm_missing $_abm_feed"
      if [ "$_abm_env" = production ]; then
        [ "${APPIDGE_ALLOW_MISSING_FEED:-}" = YES ] \
          || ops_die "production build 前无法查询 $_abm_feed 确认 build 号单调性——fail closed。首发时该 feed 尚不存在属预期，用 APPIDGE_ALLOW_MISSING_FEED=YES 一次性放行（仍强制另一个 feed 的单调性）"
        ops_warn "⚠️ APPIDGE_ALLOW_MISSING_FEED=YES：跳过 ${_abm_feed} 的单调性校验。仅限首发,别设成常态。"
      else
        ops_warn "无法查询 ${_abm_feed}（可能尚未发布过）——staging 允许继续，但请人工确认 build 号"
      fi
    fi
  done
  if [ "$_abm_env" = production ] && [ -n "$_abm_missing" ] && [ "$_abm_ok" = 0 ]; then
    ops_die "全部 feed 都查不到（${_abm_missing# }）——没有任何 build 号单调性证据，拒绝出包（APPIDGE_ALLOW_MISSING_FEED 也不放行这种情况）"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 环境配置读取：allowlist keys、POSIX sourceable、APPIDGE_ENVIRONMENT 与参数一致。
# 测试可用 APPIDGE_OPS_CONFIG_DIR 指向 fixture 目录。
# ---------------------------------------------------------------------------
OPS_ALLOW_KEYS='APPIDGE_ENVIRONMENT PUBLIC_SITE_URL PUBLIC_POLAR_CHECKOUT_URL PUBLIC_API_BASE_URL PUBLIC_DOWNLOAD_URL LICENSE_API_BASE_URL LICENSE_CHECKOUT_URL SPARKLE_FEED_URL SITE_BASE_URL TRIAL_DURATION_DAYS API_D1_DATABASE_NAME'

load_environment() { # $1 = staging|production
  OPS_ENV=$1
  case "$OPS_ENV" in
    staging|production) ;;
    *) ops_die "未知环境：${OPS_ENV}（只支持 staging|production）" ;;
  esac
  OPS_CONF="${APPIDGE_OPS_CONFIG_DIR:-$OPS_ROOT/ops/environments}/$OPS_ENV.conf"
  [ -f "$OPS_CONF" ] || ops_die "缺环境配置：$OPS_CONF"

  # allowlist：出现任何计划外的 key 直接失败（防 secret / 私货混入）
  for k in $(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$OPS_CONF" | cut -d= -f1); do
    case " $OPS_ALLOW_KEYS " in
      *" $k "*) ;;
      *) ops_die "$OPS_CONF 含非 allowlist key：${k}（契约见 free-plan 文档 §5.3）" ;;
    esac
  done

  # shellcheck disable=SC1090
  . "$OPS_CONF"

  [ "${APPIDGE_ENVIRONMENT:-}" = "$OPS_ENV" ] \
    || ops_die "$OPS_CONF 内 APPIDGE_ENVIRONMENT='${APPIDGE_ENVIRONMENT:-}' 与请求环境 '$OPS_ENV' 不一致"
}

# ---------------------------------------------------------------------------
# URL / 环境交叉校验（fail_add 累积）。
# ---------------------------------------------------------------------------
validate_config_urls() { # 依赖 load_environment 已执行
  _env=$OPS_ENV

  for k in PUBLIC_SITE_URL PUBLIC_POLAR_CHECKOUT_URL PUBLIC_API_BASE_URL \
           PUBLIC_DOWNLOAD_URL LICENSE_API_BASE_URL LICENSE_CHECKOUT_URL SPARKLE_FEED_URL \
           SITE_BASE_URL; do
    eval "v=\${$k:-}"
    if is_placeholder "$v"; then
      case "$k" in
        PUBLIC_POLAR_CHECKOUT_URL)
          fail_add "$k 缺真实 CHECKOUT 链接（当前：${v:-空}）——人工闸门，由用户提供 Creem live 支付链接" ;;
        *)
          fail_add "$k 是占位/空值：${v:-空}" ;;
      esac
      continue
    fi
    case "$v" in
      https://*) ;;
      *) fail_add "$k 必须是 HTTPS URL：$v"; continue ;;
    esac
    case "$v" in
      *localhost*|*.invalid*|*.invalid/*)
        fail_add "$k 不得指向 localhost/.invalid：$v"; continue ;;
    esac
    # checkout URL 不得是 API token 形态
    case "$v" in
      *polar_oat_*|*creem_test_*|*creem_live_*|*whsec_*) fail_add "$k 疑似包含 API token/secret：拒绝" ; continue ;;
    esac

    if [ "$_env" = production ]; then
      case "$v" in
        *staging*|*sandbox*|*PLACEHOLDER*)
          fail_add "production $k 不得包含 staging/sandbox/PLACEHOLDER：$v"; continue ;;
      esac
    fi

    # appidge 自有域按环境精确匹配（防交叉：staging 包指向 prod feed 或反之）
    h=$(url_host "$v")
    case "$k" in
      PUBLIC_SITE_URL|SITE_BASE_URL)
        if [ "$_env" = staging ]; then
          [ "$h" = "staging.appidge.com" ] || fail_add "staging $k host 应为 staging.appidge.com：$h"
        else
          case "$h" in appidge.com|www.appidge.com) ;; *) fail_add "production $k host 应为 appidge.com：$h" ;; esac
        fi ;;
      PUBLIC_API_BASE_URL|LICENSE_API_BASE_URL)
        if [ "$_env" = staging ]; then
          [ "$h" = "api-staging.appidge.com" ] || fail_add "staging $k host 应为 api-staging.appidge.com：$h"
        else
          [ "$h" = "api.appidge.com" ] || fail_add "production $k host 应为 api.appidge.com：$h"
        fi ;;
      PUBLIC_DOWNLOAD_URL|SPARKLE_FEED_URL)
        if [ "$_env" = staging ]; then
          [ "$h" = "updates-staging.appidge.com" ] || fail_add "staging $k host 应为 updates-staging.appidge.com（环境交叉）：$h"
        else
          [ "$h" = "updates.appidge.com" ] || fail_add "production $k host 应为 updates.appidge.com（环境交叉）：$h"
        fi ;;
      LICENSE_CHECKOUT_URL)
        # App 内「购买」指向本环境官网的定价锚点，绝不直连支付商：
        # 保留 App→官网间接层，换 checkout 链接无需重发 macOS App。
        # 单页信息架构下 /pricing 独立页已撤（aef5a5d），落地页是首页 #pricing 锚点。
        if [ "$_env" = staging ]; then
          [ "$h" = "staging.appidge.com" ] || fail_add "staging $k host 应为 staging.appidge.com（环境交叉）：$v"
        else
          [ "$h" = "appidge.com" ] || fail_add "production $k host 应为 appidge.com：$v"
        fi
        case "$v" in
          *'/#pricing') ;;
          *) fail_add "$_env $k 应落到官网定价锚点 /#pricing（/pricing 独立页已撤，会 404）：$v" ;;
        esac ;;
      PUBLIC_POLAR_CHECKOUT_URL)
        if [ "$_env" = staging ]; then
          case "$v" in
            https://www.creem.io/test/*|https://creem.io/test/*) ;;
            *) fail_add "staging checkout 应是 Creem test 支付链接（https://www.creem.io/test/...）：$v" ;;
          esac
        else
          case "$h" in
            www.creem.io|creem.io) ;;
            *) fail_add "production checkout 应是 Creem 支付链接（host creem.io）：$h" ;;
          esac
          case "$v" in
            */test/*) fail_add "production checkout 不得是 Creem test 链接（含 /test/）：$v" ;;
          esac
        fi ;;
    esac
  done

  # SITE_BASE_URL 必须与 PUBLIC_SITE_URL 同源（防环境交叉：站点跳转与官网构建落在同一环境）
  if [ -n "${SITE_BASE_URL:-}" ] && [ -n "${PUBLIC_SITE_URL:-}" ]; then
    [ "$(url_host "$SITE_BASE_URL")" = "$(url_host "$PUBLIC_SITE_URL")" ] \
      || fail_add "SITE_BASE_URL host（$(url_host "$SITE_BASE_URL")）应与 PUBLIC_SITE_URL host（$(url_host "$PUBLIC_SITE_URL")）同源"
  fi

  # TRIAL_DURATION_DAYS 必须是正整数（production 固定 7；staging 可调小便于调试）
  case "${TRIAL_DURATION_DAYS:-}" in
    ''|*[!0-9]*|0) fail_add "TRIAL_DURATION_DAYS 应为正整数：${TRIAL_DURATION_DAYS:-空}" ;;
    *) [ "$_env" != production ] || [ "$TRIAL_DURATION_DAYS" = 7 ] \
         || fail_add "production TRIAL_DURATION_DAYS 应为 7：$TRIAL_DURATION_DAYS" ;;
  esac

  [ "${API_D1_DATABASE_NAME:-}" = "appidge-licensing-$_env" ] \
    || fail_add "API_D1_DATABASE_NAME 应为 appidge-licensing-${_env}：${API_D1_DATABASE_NAME:-空}"
}

# ---------------------------------------------------------------------------
# Wrangler 拓扑校验：routes 与环境配置一致、updates 双环境不重复、API prod route 存在。
# ---------------------------------------------------------------------------
wrangler_env_pattern() { # $1=jsonc 文件 $2=env 名 → 第一个 route pattern
  awk -v env="\"$2\"" '
    index($0, env ":") { f = 1 }
    f && /"pattern"/ {
      line = $0
      sub(/.*"pattern"[^"]*"/, "", line); sub(/".*/, "", line)
      print line; exit
    }' "$1"
}

api_prod_section() { awk '/^\[env\.production/ { f = 1 } f' "$OPS_ROOT/apps/api/wrangler.toml"; }

validate_wrangler_topology() {
  upd="$OPS_ROOT/infra/updates/wrangler.jsonc"
  web="$OPS_ROOT/apps/web/wrangler.jsonc"

  u_stg=$(wrangler_env_pattern "$upd" staging)
  u_prd=$(wrangler_env_pattern "$upd" production)
  [ "$u_stg" = "updates-staging.appidge.com" ] \
    || fail_add "infra/updates staging route 应为 updates-staging.appidge.com：${u_stg:-空}"
  [ "$u_prd" = "updates.appidge.com" ] \
    || fail_add "infra/updates production route 应为 updates.appidge.com：${u_prd:-空}"
  [ -n "$u_stg" ] && [ "$u_stg" = "$u_prd" ] \
    && fail_add "staging/production updates hostname 重复：${u_stg}（一个自定义域只能挂一个 Worker）"

  api_prod_section | grep -q 'pattern *= *"api\.appidge\.com"' \
    || fail_add "apps/api/wrangler.toml 缺 production route api.appidge.com"

  w_stg=$(wrangler_env_pattern "$web" staging)
  [ "$w_stg" = "staging.appidge.com" ] \
    || fail_add "apps/web staging route 应为 staging.appidge.com：${w_stg:-空}"
  grep -q '"pattern": *"appidge\.com"' "$web" \
    || fail_add "apps/web 缺 production route appidge.com"
}

# ---------------------------------------------------------------------------
# production 真实资源占位检测（fail closed 的核心）。
# ---------------------------------------------------------------------------
validate_production_identifiers() {
  [ "$OPS_ENV" = production ] || return 0
  sec=$(api_prod_section)
  for var in CREEM_PRODUCT_ID; do
    val=$(printf '%s\n' "$sec" | grep -E "^$var *= *\"" | head -1 | cut -d'"' -f2)
    if is_placeholder "$val"; then
      fail_add "apps/api/wrangler.toml [env.production] $var 是占位：${val:-空}——人工闸门，由用户提供真实 Creem live product id"
    fi
  done
  d1id=$(printf '%s\n' "$sec" | grep -E '^database_id *= *"' | head -1 | cut -d'"' -f2)
  if is_placeholder "$d1id"; then
    fail_add "apps/api/wrangler.toml [env.production] D1 database_id 是占位——人工闸门：wrangler d1 create appidge-licensing-production 后回填"
  fi
}

# ---------------------------------------------------------------------------
# 工具依赖。
# ---------------------------------------------------------------------------
check_tools() {
  command -v git  >/dev/null 2>&1 || fail_add "缺 git"
  command -v node >/dev/null 2>&1 || fail_add "缺 node（>=22）"
  command -v pnpm >/dev/null 2>&1 || fail_add "缺 pnpm（>=10）"
  if [ ! -d "$OPS_ROOT/apps/api/node_modules" ]; then
    fail_add "apps/api/node_modules 缺失——先 pnpm install --frozen-lockfile（wrangler 由 workspace 提供）"
  fi
}

wrangler_run() { # $1 = api|web|updates，其余为 wrangler 参数（updates/web 无自带依赖，共用 api 的 wrangler）
  # 注意：必须直接调 api workspace 的 wrangler 二进制，并靠 cd 决定配置目录。
  # 不能用 `pnpm --dir apps/api exec`：--dir 会把 cwd 拉回 apps/api，
  # 使 web/updates 的 deploy 与 dry-run 实际作用于 api Worker（已有回归测试覆盖）。
  _dir=$1; shift
  _wrangler="$OPS_ROOT/apps/api/node_modules/.bin/wrangler"
  [ -x "$_wrangler" ] || ops_die "wrangler_run: 缺少 ${_wrangler}（先在仓库根 pnpm install）"
  case "$_dir" in
    api)     ( cd "$OPS_ROOT/apps/api"      && "$_wrangler" "$@" ) ;;
    web)     ( cd "$OPS_ROOT/apps/web"      && "$_wrangler" "$@" ) ;;
    updates) ( cd "$OPS_ROOT/infra/updates" && "$_wrangler" "$@" ) ;;
    *) ops_die "wrangler_run: 未知目录 $_dir" ;;
  esac
}

# ---------------------------------------------------------------------------
# 生产写保护（三重）：--apply + --confirm-production + APPIDGE_PRODUCTION_APPROVED=YES。
# 任何远端写路径都必须先过这里；不能仅凭 environment=production 就执行。
# ---------------------------------------------------------------------------
guard_remote_write() { # $1=env $2=apply(0/1) $3=confirm(0/1)
  _e=$1; _a=$2; _c=$3
  [ "$_a" = 1 ] || ops_die "远端写操作需要显式 --apply（当前为 [plan-only]，未修改远端）"
  if [ "$_e" = production ]; then
    [ "$_c" = 1 ] \
      || ops_die "production 写操作需要 --confirm-production（三重保护 2/3 缺失，fail closed）"
    [ "${APPIDGE_PRODUCTION_APPROVED:-}" = "YES" ] \
      || ops_die "production 写操作需要环境变量 APPIDGE_PRODUCTION_APPROVED=YES（三重保护 3/3 缺失，fail closed）"
  fi
}

# ---------------------------------------------------------------------------
# Workers Static Assets：Free 单文件上限 25 MiB。超过 → 拒绝部署并提示迁 R2，不静默跳过。
# ---------------------------------------------------------------------------
OPS_MAX_ASSET_BYTES=26214400
file_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null; }

assert_static_assets_within_limit() { # $1=目录
  _d=$1
  [ -d "$_d" ] || { echo "assert_static_assets_within_limit: 目录不存在 $_d" >&2; return 1; }
  _bad=0
  for f in $(find "$_d" -type f 2>/dev/null); do
    _sz=$(file_size "$f")
    if [ "${_sz:-0}" -gt "$OPS_MAX_ASSET_BYTES" ]; then
      echo "静态文件超过 Workers Free 单文件 25MiB 限制：${f}（$_sz 字节）——请迁移 DMG 到 R2 后再发布" >&2
      _bad=1
    fi
  done
  [ "$_bad" = 0 ]
}

# ---------------------------------------------------------------------------
# 输出头：environment、Git SHA、目标 hostname、D1；绝不输出 secret。
# ---------------------------------------------------------------------------
print_header() {
  sha=$(git -C "$OPS_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
  ops_note "environment : $OPS_ENV"
  ops_note "git sha     : $sha"
  ops_note "web         : $(url_host "${PUBLIC_SITE_URL:-}")"
  ops_note "api         : $(url_host "${PUBLIC_API_BASE_URL:-}")"
  ops_note "updates     : $(url_host "${PUBLIC_DOWNLOAD_URL:-}")"
  ops_note "d1          : ${API_D1_DATABASE_NAME:-}"
}

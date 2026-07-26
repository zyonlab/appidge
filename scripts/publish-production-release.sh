#!/bin/sh
# scripts/publish-production-release.sh —— production 发布链第 4~8 步的串行入口（fail-fast）。
#
#   scripts/publish-production-release.sh <build-number> [--allow-missing-feed]
#
# 覆盖：build-macos → prepare-updates → publish-updates → smoke → release-manifest。
# 不含 migrate-api / deploy-api / deploy-web（云端三件，另行用 appidge-ops 单独跑）。
#
# 调用前必须自己 export APPIDGE_PRODUCTION_APPROVED=YES —— 本脚本**故意不替你设**，
# 那是三重生产保护里代表「人已审批」的那一重，脚本自动补上就等于把闸门拆了。
#
#   APPIDGE_PRODUCTION_APPROVED=YES scripts/publish-production-release.sh 79 --allow-missing-feed
#
# --allow-missing-feed：仅首发用。updates.appidge.com 的 appcast 要到 publish-updates
# 才存在，而 build-macos 在它之前就要求该 feed 可查 ⇒ 首个 production 包出不来。
# 该开关只免除**查不到的那个 feed**，另一个 feed 的单调性照旧强制（见 ops/README.md）。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
OPS="$ROOT/ops/bin/appidge-ops"

BUILD_NUMBER=${1:-}
case "$BUILD_NUMBER" in
  ''|*[!0-9]*|0) echo "用法：$0 <build-number> [--allow-missing-feed]" >&2; exit 2 ;;
esac
shift

ALLOW_MISSING_FEED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-missing-feed) ALLOW_MISSING_FEED=YES ;;
    *) echo "未知选项：$1" >&2; exit 2 ;;
  esac
  shift
done

[ "${APPIDGE_PRODUCTION_APPROVED:-}" = YES ] || {
  echo "拒绝：需要 APPIDGE_PRODUCTION_APPROVED=YES（三重生产保护之一，脚本不代设）" >&2
  echo "  APPIDGE_PRODUCTION_APPROVED=YES $0 $BUILD_NUMBER${ALLOW_MISSING_FEED:+ --allow-missing-feed}" >&2
  exit 2
}

step() { printf '\n══════ %s ══════\n' "$*"; }

step "0/6 签名时间戳探针（代理若在接管，这里就该停，别等 archive 跑几分钟才死）"
sh "$ROOT/scripts/check-signing-timestamp.sh"

step "1/6 build-macos production --build-number $BUILD_NUMBER"
# 归档 + 签名 + 公证 + DMG，数分钟。build 号单调性在这一步强制。
APPIDGE_ALLOW_MISSING_FEED="$ALLOW_MISSING_FEED" \
  "$OPS" build-macos production --build-number "$BUILD_NUMBER"

step "2/6 prepare-updates production --build-number $BUILD_NUMBER（本地生成 appcast，未发布）"
# generate_appcast 会用 Keychain 里的 Sparkle EdDSA 私钥签名——可能弹一次钥匙串授权，点允许。
"$OPS" prepare-updates production --build-number "$BUILD_NUMBER"

step "3/6 publish-updates production（远端写：DMG + latest + appcast 同版本原子上线）"
"$OPS" publish-updates production --apply --confirm-production --build-number "$BUILD_NUMBER"

step "4/6 等 updates.appidge.com 稳定（首次建自定义域，证书分批下发，单次 200 不作数）"
streak=0; i=0
while [ $i -lt 90 ]; do
  i=$((i + 1))
  if curl -fsS -o /dev/null -m 10 "https://updates.appidge.com/appcast.xml" 2>/dev/null; then
    streak=$((streak + 1))
    printf '  [%s] OK streak=%s\n' "$i" "$streak"
    [ "$streak" -ge 10 ] && break
  else
    [ "$streak" -gt 0 ] && printf '  [%s] 失败（streak 从 %s 归零）\n' "$i" "$streak" || printf '  [%s] 尚未就绪\n' "$i"
    streak=0
  fi
  sleep 10
done
[ "$streak" -ge 10 ] || {
  echo "appcast 未达成 10 次连续成功——先别急着回滚，Worker 多半已发布成功，是证书还在传播。" >&2
  echo "手工复查：curl -fsS https://updates.appidge.com/appcast.xml" >&2
  exit 1
}

step "5/6 smoke production --build-number $BUILD_NUMBER"
"$OPS" smoke production --build-number "$BUILD_NUMBER"

step "6/6 release-manifest production --build-number $BUILD_NUMBER"
"$OPS" release-manifest production --build-number "$BUILD_NUMBER"

cat <<EOF

══════ 发布链跑完 ══════
剩下的是真机人工闸门，脚本证明不了：
  1. 从上一版 App 走一次真实 Sparkle 升级（含系统扩展重绑），确认没有升级黑洞。
     scripts/verify-staging-update.sh --feed https://updates.appidge.com/appcast.xml
  2. 官网下载 CTA 点一次，确认拿到的是 build $BUILD_NUMBER 的 DMG。
EOF

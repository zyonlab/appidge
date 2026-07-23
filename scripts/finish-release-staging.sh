#!/bin/sh
# scripts/finish-release-staging.sh —— 兼容 wrapper（逻辑已迁移到 ops/bin/appidge-ops）。
#
# 旧版本「续跑 staging 发布」（DMG 公证 → appcast → 部署 → 还原 AppConfig）已由
# appidge-ops 的 prepare-updates / publish-updates 取代：不改写 tracked 配置、
# staging feed 固定 updates-staging.appidge.com、发布前做 25MiB/host/签名一致性检查。
#
# 用法：
#   scripts/finish-release-staging.sh --build-number <N>            # 只本地准备（prepare-updates）
#   scripts/finish-release-staging.sh --build-number <N> --apply    # 准备 + 真实发布（publish-updates）
# 远端发布必须显式 --apply；无参数运行只显示用法并退出非零。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPS="$ROOT/ops/bin/appidge-ops"

usage() {
  cat >&2 <<'EOF'
scripts/finish-release-staging.sh 已改为 ops/bin/appidge-ops 的兼容 wrapper。

  scripts/finish-release-staging.sh --build-number <N>            # prepare-updates staging（只本地）
  scripts/finish-release-staging.sh --build-number <N> --apply    # + publish-updates staging --apply

等价于：
  ops/bin/appidge-ops prepare-updates staging --build-number <N>
  ops/bin/appidge-ops publish-updates staging --apply --build-number <N>
EOF
}

[ $# -gt 0 ] || { usage; exit 2; }
[ -x "$OPS" ] || { echo "缺 $OPS" >&2; exit 1; }

APPLY=0
BUILD_NUMBER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --build-number) shift; BUILD_NUMBER="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
  shift
done
[ -n "$BUILD_NUMBER" ] || { usage; exit 2; }

"$OPS" prepare-updates staging --build-number "$BUILD_NUMBER"
if [ "$APPLY" = 1 ]; then
  exec "$OPS" publish-updates staging --apply --build-number "$BUILD_NUMBER"
else
  echo "[finish-release-staging] 已完成本地准备。真实发布需显式 --apply（将执行 publish-updates staging --apply）。"
fi

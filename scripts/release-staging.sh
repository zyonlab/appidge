#!/bin/sh
# scripts/release-staging.sh —— 兼容 wrapper（逻辑已迁移到 ops/bin/appidge-ops）。
#
# 旧版本是一条全量 staging 发布脚本：硬编码个人绝对路径、临时改写 Config/AppConfig.xcconfig、
# staging feed 指向 production updates 域、App 购买入口直连 Polar sandbox。这些副作用已全部
# 移除：环境矩阵在 ops/environments/staging.conf，发布动作全部经 appidge-ops（含 preflight、
# 25MiB/host 一致性检查、--apply 显式远端写保护）。
#
# 无参数运行只显示新用法并退出非零，避免误触发发布。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPS="$ROOT/ops/bin/appidge-ops"

usage() {
  cat >&2 <<'EOF'
scripts/release-staging.sh 已改为 ops/bin/appidge-ops 的兼容 wrapper，不再直接发布。

staging 发布（每步显式、可 dry-run；<N> 为全局单调递增 build 号）：
  ops/bin/appidge-ops preflight staging
  ops/bin/appidge-ops build-macos staging --build-number <N>
  ops/bin/appidge-ops prepare-updates staging --build-number <N>
  ops/bin/appidge-ops publish-updates staging --apply --build-number <N>
  ops/bin/appidge-ops smoke staging

本 wrapper 用法：scripts/release-staging.sh <appidge-ops 子命令与参数...>
（等价于直接调用 ops/bin/appidge-ops；无参数时只显示本说明并退出 2。）
EOF
}

[ $# -gt 0 ] || { usage; exit 2; }
[ -x "$OPS" ] || { echo "缺 $OPS" >&2; exit 1; }
exec "$OPS" "$@"

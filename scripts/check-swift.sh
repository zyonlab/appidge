#!/usr/bin/env bash
# check-swift.sh —— 只包装可重复的 Swift package tests，不触碰签名/公证/DMG。
# 与 CI 的 spm-tests job 对齐：Core / IPCContract / EngineKit / AppFeature / ArchitectureTests。
# 用法: pnpm check:swift   或   bash scripts/check-swift.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKGS=(Core IPCContract EngineKit AppFeature ArchitectureTests)

echo "swift toolchain: $(swift --version 2>/dev/null | head -1 || echo 'not found')"

fail=0
for pkg in "${PKGS[@]}"; do
  dir="$ROOT/Packages/$pkg"
  if [ ! -d "$dir" ]; then
    echo "!! missing package: $pkg" >&2
    fail=1
    continue
  fi
  echo "::group::swift test — $pkg"
  if (cd "$dir" && swift test); then
    echo "ok — $pkg"
  else
    echo "FAIL — $pkg" >&2
    fail=1
  fi
  echo "::endgroup::"
done

exit "$fail"

#!/bin/sh
# ops/tests/test-extension-version.sh —— 扩展版本解耦守门闸（scripts/check-extension-version.sh）
# 的无网络回归测试。用 mktemp fixture 仓库根（APPIDGE_EXT_CHECK_ROOT 覆盖），覆盖：
#   初始化 / 内容变更未 bump / bump 后未登记 / --update 闭环 / 无谓 bump / 版本回退 /
#   依赖包（EngineKit/IPCContract）变更同样触发 / 文件改名触发。
# 可在 macOS /bin/sh 下运行；不触碰真实仓库的 lock。
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CHECK="$ROOT/scripts/check-extension-version.sh"

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

expect_ok() {
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then t_pass "$desc"; else t_fail "$desc"; fi
}
expect_fail() {
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then t_fail "${desc}（预期失败但成功了）"; else t_pass "$desc"; fi
}

FIX=$(mktemp -d "${TMPDIR:-/tmp}/appidge-extver-test.XXXXXX")
trap 'rm -rf "$FIX"' EXIT INT TERM

# fixture 仓库根：最小内容闭包 + project.yml 钉版本
mkdir -p "$FIX/Extension" "$FIX/scripts" \
         "$FIX/Packages/EngineKit/Sources/EngineKit" \
         "$FIX/Packages/IPCContract/Sources/IPCContract"
echo 'provider v1' > "$FIX/Extension/Provider.swift"
echo 'engine v1'   > "$FIX/Packages/EngineKit/Sources/EngineKit/Engine.swift"
echo 'ipc v1'      > "$FIX/Packages/IPCContract/Sources/IPCContract/Contract.swift"
echo 'pkg engine'  > "$FIX/Packages/EngineKit/Package.swift"
echo 'pkg ipc'     > "$FIX/Packages/IPCContract/Package.swift"

set_version() { # $1=build $2=marketing
  cat > "$FIX/project.yml" <<EOF
targets:
  ProxyExtension:
    settings:
      base:
        APPIDGE_EXT_MARKETING_VERSION: "$2"
        APPIDGE_EXT_BUILD_NUMBER: "$1"
EOF
}
run() { APPIDGE_EXT_CHECK_ROOT="$FIX" sh "$CHECK" "$@"; }

echo "== ops/tests/test-extension-version.sh =="
echo "fixture: $FIX"
echo

set_version 81 "0.2.35"

# --- 初始化与基线 ---
expect_fail "缺 lock 时校验 fail closed"                       run
expect_ok   "--update 初始化 lock"                             run --update
expect_ok   "内容/版本未动 → 校验通过"                          run
expect_ok   "lock 文件已生成"                                   test -f "$FIX/scripts/extension-version.lock"

# --- 内容变更未 bump：核心风险，必须硬失败 ---
echo 'provider v2' > "$FIX/Extension/Provider.swift"
expect_fail "Extension/ 内容变更但版本未 bump → 拒绝"           run
expect_fail "--update 也不放行内容变更未 bump"                  run --update
# 未发布版本的开发迭代逃生口:显式 --same-version 才放行,且随后校验通过
expect_ok   "--update --same-version 同版本重登记(未发布迭代)"  run --update --same-version
expect_ok   "同版本重登记后校验通过"                            run
echo 'provider v2b' > "$FIX/Extension/Provider.swift"

# --- bump 后必须 --update 登记 ---
set_version 82 "0.2.35"
expect_fail "已 bump 但 lock 未登记 → 校验仍拒绝"               run
expect_ok   "bump 后 --update 重新登记"                         run --update
expect_ok   "登记后校验通过"                                    run

# --- 无谓 bump（内容没变却改版本）→ 重新打开替换窗口，拒绝 ---
set_version 83 "0.2.35"
expect_fail "内容未变却 bump 版本 → 校验拒绝（无谓替换窗口）"    run
expect_ok   "确需强制替换时 --update 可显式登记"                 run --update
set_version 83 "0.2.36"
expect_fail "内容未变却改 marketing → 同样拒绝"                  run
set_version 83 "0.2.35"

# --- 版本回退 ---
echo 'provider v3' > "$FIX/Extension/Provider.swift"
set_version 82 "0.2.35"
expect_fail "--update 拒绝 build 回退（83→82）"                 run --update
set_version 84 "0.2.35"
expect_ok   "回退纠正后 --update 通过"                          run --update

# --- 依赖包闭包同样进指纹 ---
echo 'engine v2' > "$FIX/Packages/EngineKit/Sources/EngineKit/Engine.swift"
expect_fail "EngineKit 源码变更同样触发"                        run
set_version 85 "0.2.35"; run --update >/dev/null 2>&1
echo 'ipc v2' > "$FIX/Packages/IPCContract/Sources/IPCContract/Contract.swift"
expect_fail "IPCContract 源码变更同样触发"                      run
set_version 86 "0.2.35"; run --update >/dev/null 2>&1
echo 'pkg engine v2' > "$FIX/Packages/EngineKit/Package.swift"
expect_fail "Package.swift 变更同样触发"                        run
set_version 87 "0.2.35"; run --update >/dev/null 2>&1

# --- 文件改名也翻新指纹（指纹含相对路径）---
mv "$FIX/Extension/Provider.swift" "$FIX/Extension/Provider2.swift"
expect_fail "文件改名（内容不变）同样触发"                       run

# --- project.yml 缺键 fail closed ---
cat > "$FIX/project.yml" <<'EOF'
targets:
  ProxyExtension:
    settings:
      base:
        OTHER: "x"
EOF
expect_fail "project.yml 缺 APPIDGE_EXT_BUILD_NUMBER → fail closed" run

echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] || { printf '%s' "$FAILED_LIST"; exit 1; }

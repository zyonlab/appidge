#!/bin/sh
# scripts/check-extension-version.sh —— 系统扩展「内容变了必须 bump 版本」的守门闸。
#
# 背景（升级黑洞的根本缓解）：扩展版本已与 app build 号解耦——macOS 按
# (CFBundleShortVersionString, CFBundleVersion) 元组判断系统扩展是否需要替换，替换窗口
# 正是「会话绑死旧 provider / 新进程 XPC 监听器注册失败」竞态的唯一入口。扩展内容没变的
# 发版保持版本不动 → 系统跳过替换 → 竞态窗口不存在。
#
# 解耦引入的反向风险：改了扩展却忘 bump → 系统永远不装新扩展、用户一直跑旧行为，
# 且版本握手两边相等、自愈永不触发。本脚本把这个风险变成**构建期硬失败**：
# 扩展二进制的内容闭包（Extension/ + EngineKit + IPCContract 的 Sources+Package.swift）
# 指纹必须与 scripts/extension-version.lock 登记的一致，否则拒绝出包。
#
# 已知盲区（罕见，改动时人工判断）：project.yml 里 ProxyExtension 的构建设置、
# Xcode/SDK 版本变化不进指纹——它们也可能改变二进制行为，若确需强制替换扩展，
# bump APPIDGE_EXT_BUILD_NUMBER 后用 --update 显式登记即可。
#
# 用法：
#   scripts/check-extension-version.sh            校验（archive-and-notarize.sh 出包前置闸门）
#   scripts/check-extension-version.sh --update   内容/版本变更后重写 lock（先在 project.yml bump）
#   scripts/check-extension-version.sh --update --same-version
#       同版本重登记——仅限「已 bump 但该版本尚未发布,继续迭代扩展内容」的开发期;
#       对已发布的版本用它 = 系统跳过替换、用户永远拿不到新扩展,严禁。
#
# 测试：ops/tests/test-extension-version.sh（APPIDGE_EXT_CHECK_ROOT 指向 fixture 仓库根）。
set -eu

# lock 放 scripts/ 而非 Extension/——xcodegen 会把 Extension/ 下的非源码文件当资源打进
# .systemextension bundle，登记文件不该进产物。
ROOT=${APPIDGE_EXT_CHECK_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
LOCK="$ROOT/scripts/extension-version.lock"
PROJECT_YML="$ROOT/project.yml"

die() { echo "[check-extension-version] $*" >&2; exit 1; }
note() { echo "[check-extension-version] $*"; }

[ -f "$PROJECT_YML" ] || die "缺 $PROJECT_YML"

# 内容闭包指纹：相对路径 + 每文件 sha256，定序后整体再 sha256。
# 包含相对路径 → 文件改名也会翻新指纹；.DS_Store 排除。
content_hash() {
  {
    find "$ROOT/Extension" \
         "$ROOT/Packages/EngineKit/Sources" \
         "$ROOT/Packages/IPCContract/Sources" \
         -type f ! -name .DS_Store
    echo "$ROOT/Packages/EngineKit/Package.swift"
    echo "$ROOT/Packages/IPCContract/Package.swift"
  } | LC_ALL=C sort | while IFS= read -r f; do
    rel=${f#"$ROOT"/}
    printf '%s  %s\n' "$(/usr/bin/shasum -a 256 "$f" | awk '{print $1}')" "$rel"
  done | /usr/bin/shasum -a 256 | awk '{print $1}'
}

# 从 project.yml 读钉住的扩展版本（值带引号或不带都接受，取首个匹配）。
yml_value() {
  sed -n "s/^[[:space:]]*$1:[[:space:]]*\"\{0,1\}\([^\"#]*\)\"\{0,1\}.*/\1/p" "$PROJECT_YML" \
    | head -1 | sed 's/[[:space:]]*$//'
}

EXT_BUILD=$(yml_value APPIDGE_EXT_BUILD_NUMBER)
EXT_MARKETING=$(yml_value APPIDGE_EXT_MARKETING_VERSION)
case "$EXT_BUILD" in
  ''|*[!0-9]*) die "project.yml 缺有效的 APPIDGE_EXT_BUILD_NUMBER（读到：'$EXT_BUILD'）" ;;
esac
[ -n "$EXT_MARKETING" ] || die "project.yml 缺 APPIDGE_EXT_MARKETING_VERSION"

CUR_HASH=$(content_hash)

write_lock() {
  cat > "$LOCK" <<EOF
# 由 scripts/check-extension-version.sh --update 生成，不要手改。
# 语义：扩展版本 (build/marketing) 与其二进制内容闭包指纹的绑定登记。
build=$EXT_BUILD
marketing=$EXT_MARKETING
hash=$CUR_HASH
EOF
  note "lock 已写入：build=$EXT_BUILD marketing=$EXT_MARKETING hash=${CUR_HASH%????????????????????????????????????????????????}…"
}

MODE=${1:-verify}

if [ ! -f "$LOCK" ]; then
  [ "$MODE" = "--update" ] || die "缺 $LOCK —— 首次初始化请跑：scripts/check-extension-version.sh --update"
  write_lock
  exit 0
fi

L_BUILD=$(sed -n 's/^build=//p' "$LOCK")
L_MARKETING=$(sed -n 's/^marketing=//p' "$LOCK")
L_HASH=$(sed -n 's/^hash=//p' "$LOCK")

case "$MODE" in
  verify|--verify)
    if [ "$CUR_HASH" != "$L_HASH" ]; then
      if [ "$EXT_BUILD" = "$L_BUILD" ]; then
        die "扩展内容闭包变了，但 APPIDGE_EXT_BUILD_NUMBER 没 bump（仍是 ${EXT_BUILD}）。
  发出去 macOS 会认为扩展没升级、跳过替换——用户永远跑旧扩展，版本握手也因两边相等而失明。
  修复：project.yml 里 bump APPIDGE_EXT_BUILD_NUMBER（> ${L_BUILD}），然后跑
  scripts/check-extension-version.sh --update"
      fi
      die "扩展内容与 lock 指纹不符（版本已改为 ${EXT_BUILD}，lock 登记 ${L_BUILD}）。
  确认 bump 无误后跑 scripts/check-extension-version.sh --update 重新登记"
    fi
    if [ "$EXT_BUILD" != "$L_BUILD" ] || [ "$EXT_MARKETING" != "$L_MARKETING" ]; then
      die "扩展内容没变，版本却被改（lock: $L_BUILD/$L_MARKETING → project.yml: $EXT_BUILD/${EXT_MARKETING}）。
  无谓 bump 会重新打开系统扩展替换的竞态窗口（升级黑洞的唯一入口）。
  请改回；确因外部原因（构建设置/SDK）必须强制替换时，跑 --update 显式登记"
    fi
    note "OK：扩展内容闭包未变，版本保持 $EXT_BUILD/${EXT_MARKETING}——本次发版将跳过系统扩展替换"
    ;;
  --update)
    if [ "$CUR_HASH" != "$L_HASH" ] && [ "$EXT_BUILD" = "$L_BUILD" ] && [ "${2:-}" != "--same-version" ]; then
      die "--update 拒绝：内容变了但 APPIDGE_EXT_BUILD_NUMBER 没 bump（仍是 ${EXT_BUILD}）。
  - 若 $EXT_BUILD 是**已发布**的版本：先在 project.yml bump（> ${L_BUILD}）再跑 --update。
  - 若 $EXT_BUILD **尚未发布**（bump 后仍在开发迭代）：用 --update --same-version 同版本重登记。
    已发布的版本禁止用该开关——同版本换内容 = 系统跳过替换,用户拿不到新扩展。"
    fi
    if [ "$EXT_BUILD" -lt "$L_BUILD" ]; then
      die "--update 拒绝：APPIDGE_EXT_BUILD_NUMBER 回退（$L_BUILD → ${EXT_BUILD}）。
  系统扩展版本必须单调不降，否则线上机器会被判「降级」触发意外替换"
    fi
    write_lock
    ;;
  *)
    die "未知参数：${MODE}（支持无参校验或 --update）"
    ;;
esac

#!/bin/sh
# scripts/verify-staging-update.sh
# 自动校验「已装 app 能否感知并信任更新 feed 上的最新版」——纯 headless，不点 GUI。
# 断言：feed 版本 vs 已装、DMG 长度、EdDSA 签名链（appcast 签名↔本机私钥↔app 公钥）。
# 说明：验签优先用本地 build 里的同一个 DMG（代理环境下跳过慢下载）。
#
# 参数化（环境变量或选项，默认 staging）：
#   --app <path>        已装 app 路径          （APPIDGE_VERIFY_APP，默认 /Applications/appidge.app）
#   --feed <url>        appcast feed URL       （APPIDGE_VERIFY_FEED，默认 https://updates-staging.appidge.com/appcast.xml）
#   --build-dir <path>  本地 build 产物目录    （APPIDGE_VERIFY_BUILD_DIR，默认 <repo>/build）
# production 验证：--feed https://updates.appidge.com/appcast.xml
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="${APPIDGE_VERIFY_APP:-/Applications/appidge.app}"
FEED="${APPIDGE_VERIFY_FEED:-https://updates-staging.appidge.com/appcast.xml}"
BUILD_DIR="${APPIDGE_VERIFY_BUILD_DIR:-$ROOT/build}"

while [ $# -gt 0 ]; do
  case "$1" in
    --app) shift; APP="${1:?--app 需要路径}" ;;
    --feed) shift; FEED="${1:?--feed 需要 URL}" ;;
    --build-dir) shift; BUILD_DIR="${1:?--build-dir 需要路径}" ;;
    -h|--help)
      /usr/bin/grep '^#' "$0" | /usr/bin/sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（--app/--feed/--build-dir）" >&2; exit 2 ;;
  esac
  shift
done

case "$FEED" in
  https://*) ;;
  *) echo "feed 必须是 HTTPS URL：$FEED" >&2; exit 2 ;;
esac
[ -d "$APP" ] || { echo "app 不存在：$APP" >&2; exit 2; }

DD="$HOME/Library/Developer/Xcode/DerivedData"
SIGN_UPDATE="$(/usr/bin/find "$DD" -name sign_update -type f 2>/dev/null | /usr/bin/head -1)"
GEN_KEYS="$(/usr/bin/find "$DD" -name generate_keys -type f 2>/dev/null | /usr/bin/head -1)"

fail=0
INSTALLED=$(/usr/bin/defaults read "$APP/Contents/Info" CFBundleVersion)
XML=$(/usr/bin/curl -s -m 30 --retry 2 "$FEED")
FEED_VER=$(printf '%s' "$XML" | /usr/bin/xmllint --xpath 'string(//*[local-name()="version"])' - 2>/dev/null)
SIG=$(printf '%s' "$XML" | /usr/bin/grep -oE 'edSignature="[^"]+"' | /usr/bin/head -1 | /usr/bin/cut -d'"' -f2)
LEN=$(printf '%s' "$XML" | /usr/bin/grep -oE 'length="[0-9]+"'     | /usr/bin/head -1 | /usr/bin/grep -oE '[0-9]+')

echo "feed: $FEED"
echo "已装版本: $INSTALLED    feed 版本: ${FEED_VER}"

# 1) 版本感知（Sparkle 按 CFBundleVersion 数值比较）
if   [ "${FEED_VER}" -gt "$INSTALLED" ]; then echo "✅ [感知] feed 比已装新 → 会提示升级到 ${FEED_VER}"
elif [ "${FEED_VER}" -eq "$INSTALLED" ]; then echo "ℹ️ [感知] feed=已装（${FEED_VER}）→ 暂无更新（出新 build 后再跑本脚本即变 ✅）"
else echo "❌ [感知] feed 比已装还旧"; fail=1; fi

# 2) DMG 长度：优先用本地 build 里同一个 DMG（避开被代理拖慢的下载）
LOCAL_DMG=$(/bin/ls -t "$BUILD_DIR"/appcast/*.dmg "$BUILD_DIR"/appidge-*.dmg 2>/dev/null | /usr/bin/head -1 || true)
if [ -n "${LOCAL_DMG:-}" ] && [ -f "$LOCAL_DMG" ]; then
  DMG="$LOCAL_DMG"; echo "（验签用本地 DMG：${DMG}）"
else
  DMG="$(/usr/bin/mktemp -d)/u.dmg"; /usr/bin/curl -s -m 300 -o "${DMG}" "$(printf '%s' "$XML" | /usr/bin/grep -oE 'url="[^"]+\.dmg"' | /usr/bin/head -1 | /usr/bin/sed 's/url="//;s/"//')"
fi
GOT=$(/usr/bin/stat -f%z "${DMG}")
[ "$GOT" = "$LEN" ] && echo "✅ [长度] DMG $GOT 字节 = appcast length" || { echo "❌ [长度] $GOT ≠ appcast $LEN"; fail=1; }

# 3) 签名链：ed25519 确定性——同私钥同文件签名恒等；再断言私钥↔app 公钥配对
RESIGN=$("$SIGN_UPDATE" "${DMG}" 2>/dev/null | /usr/bin/grep -oE 'edSignature="[^"]+"' | /usr/bin/cut -d'"' -f2)
[ -n "$RESIGN" ] && [ "$RESIGN" = "$SIG" ] && echo "✅ [验签] appcast 签名 = 本机私钥重签 → 由该私钥签发" || { echo "❌ [验签] 不一致 appcast=$SIG resign=$RESIGN"; fail=1; }
PUB_KC=$("$GEN_KEYS" -p 2>/dev/null | /usr/bin/grep -oE '[A-Za-z0-9+/]{40,}=*' | /usr/bin/head -1)
PUB_APP=$(/usr/bin/defaults read "$APP/Contents/Info" SUPublicEDKey)
[ -n "${PUB_KC:-}" ] && [ "$PUB_KC" = "$PUB_APP" ] && echo "✅ [配对] 钥匙串私钥 ↔ 已装 app 公钥 配对" || { echo "❌ [配对] 公钥不符 keychain=$PUB_KC app=$PUB_APP"; fail=1; }

echo "---"
[ "$fail" = 0 ] && echo "PASS：已装 app 能感知并信任 $FEED 的更新链路。" || { echo "FAIL：见上 ❌。"; exit 1; }

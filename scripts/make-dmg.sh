#!/bin/sh
# scripts/make-dmg.sh —— 把**已公证并 staple** 的 build/export/appidge.app 打包成
# **签名 + 公证 + staple** 的 DMG,供分发/官网下载。
#
# 前置:先跑 ./scripts/archive-and-notarize.sh 产出 build/export/appidge.app(已 staple)。
# 本脚本只负责「.app → DMG」这一段:组装(app + /Applications 快捷方式)→ hdiutil 压缩 →
# codesign(Developer ID)→ notarytool 公证 DMG → stapler staple。
#
# 签名/公证凭证一律从 .env 读(同 archive-and-notarize.sh 的纪律,绝不硬编码)。
set -eu
cd "$(dirname "$0")/.."

note() { echo "[make-dmg] $*"; }

# ---------------------------------------------------------------------------
# 0. 输入 .app 必须存在且已公证 staple
# ---------------------------------------------------------------------------
APP="build/export/appidge.app"
[ -d "$APP" ] || {
  echo "缺 $APP —— 先跑 ./scripts/archive-and-notarize.sh 产出已公证 staple 的 .app" >&2
  exit 1
}
# 校验 .app 自身已被 staple(否则 DMG 里的 app 在无网环境会被 Gatekeeper 拦)。
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
  echo "$APP 还没 staple —— 请先跑 archive-and-notarize.sh 完成 .app 的公证+staple" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. .env:签名身份 + 公证凭证(与 archive-and-notarize.sh 同一套)
# ---------------------------------------------------------------------------
[ -f .env ] || { echo "缺 .env,先从 .env.example 复制并填好" >&2; exit 1; }
set -a
. ./.env
set +a
: "${TEAM_ID:?TEAM_ID missing in .env}"
: "${DEVELOPER_ID_APPLICATION:?DEVELOPER_ID_APPLICATION missing in .env}"
SIGN_IDENTITY="${SIGN_IDENTITY:-$DEVELOPER_ID_APPLICATION}"

NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-$TEAM_ID}"
USE_API_KEY=0
if [ -n "${NOTARY_API_KEY_PATH:-}${NOTARY_API_KEY_ID:-}${NOTARY_API_ISSUER_ID:-}" ]; then
  : "${NOTARY_API_KEY_PATH:?NOTARY_API_KEY_PATH missing in .env}"
  : "${NOTARY_API_KEY_ID:?NOTARY_API_KEY_ID missing in .env}"
  : "${NOTARY_API_ISSUER_ID:?NOTARY_API_ISSUER_ID missing in .env}"
  [ -f "$NOTARY_API_KEY_PATH" ] || { echo "缺 API key 文件: $NOTARY_API_KEY_PATH" >&2; exit 1; }
  USE_API_KEY=1
elif [ -n "${NOTARY_APPLE_ID:-}${NOTARY_APP_SPECIFIC_PASSWORD:-}" ]; then
  : "${NOTARY_APPLE_ID:?NOTARY_APPLE_ID missing in .env}"
  : "${NOTARY_APP_SPECIFIC_PASSWORD:?NOTARY_APP_SPECIFIC_PASSWORD missing in .env}"
  USE_API_KEY=0
else
  echo "缺公证凭证(NOTARY_API_KEY_* 或 NOTARY_APPLE_ID+NOTARY_APP_SPECIFIC_PASSWORD),见 archive-and-notarize.sh 顶部说明" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. 版本 → DMG 命名
# ---------------------------------------------------------------------------
SHORT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
VOLNAME="appidge $SHORT"
DMG="build/appidge-$SHORT-$BUILD.dmg"
STAGING="build/dmg-staging"

note "1/5 组装 DMG 内容(appidge.app + /Applications 拖装快捷方式)"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
/usr/bin/ditto "$APP" "$STAGING/appidge.app"
ln -s /Applications "$STAGING/Applications"

note "2/5 hdiutil 生成压缩 DMG(UDZO):$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

note "3/5 codesign DMG(Developer ID + 安全时间戳)"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

note "4/5 xcrun notarytool submit(阻塞到苹果给结果,可能几分钟)"
if [ "$USE_API_KEY" = 1 ]; then
  xcrun notarytool submit "$DMG" \
    --key "$NOTARY_API_KEY_PATH" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID" --wait
else
  xcrun notarytool submit "$DMG" \
    --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_APP_SPECIFIC_PASSWORD" --wait
fi

note "5/5 staple 公证票据到 DMG(离线也能过 Gatekeeper)"
xcrun stapler staple "$DMG"

note "完成:$DMG —— 已签名、公证、staple,可分发"
# DMG 的 Gatekeeper 评估类型是 open(不是 exec),据此验证。
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | tail -3 || true

#!/bin/sh
# 从 .env 生成 Config/Signing.xcconfig（gitignored）。Xcode 只认 xcconfig，不认 .env。
# 绝不把签名信息写进源码或 git 历史。
set -eu
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "缺 .env，先从 .env.example 复制并填好" >&2; exit 1; }
set -a
. ./.env
set +a

: "${TEAM_ID:?TEAM_ID missing in .env}"
: "${DEVELOPER_ID_APPLICATION:?DEVELOPER_ID_APPLICATION missing in .env}"
: "${APP_BUNDLE_ID:?APP_BUNDLE_ID missing in .env}"
: "${EXT_BUNDLE_ID:?EXT_BUNDLE_ID missing in .env}"
: "${APP_GROUP:?APP_GROUP missing in .env}"
: "${PROFILE_APP:?PROFILE_APP missing in .env}"
: "${PROFILE_EXT:?PROFILE_EXT missing in .env}"

[ -f "$PROFILE_APP" ] || { echo "缺 provisionprofile: $PROFILE_APP" >&2; exit 1; }
[ -f "$PROFILE_EXT" ] || { echo "缺 provisionprofile: $PROFILE_EXT" >&2; exit 1; }

SIGN_IDENTITY="${SIGN_IDENTITY:-$DEVELOPER_ID_APPLICATION}"

extract_field() {
  security cms -D -i "$1" 2>/dev/null | plutil -extract "$2" xml1 -o - - 2>/dev/null | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p'
}

# UUID 优先用 .env 里已经填好的 PROFILE_APP_UUID/PROFILE_EXT_UUID（跳过 security/plutil 解析，
# 更快、也不依赖这两个工具在场）；没填就照旧从 profile 文件里自动解析。
APP_PROFILE_UUID="${PROFILE_APP_UUID:-$(extract_field "$PROFILE_APP" UUID)}"
EXT_PROFILE_UUID="${PROFILE_EXT_UUID:-$(extract_field "$PROFILE_EXT" UUID)}"
APP_PROFILE_NAME="$(extract_field "$PROFILE_APP" Name)"
EXT_PROFILE_NAME="$(extract_field "$PROFILE_EXT" Name)"

: "${APP_PROFILE_UUID:?无法从 $PROFILE_APP 解析 UUID}"
: "${EXT_PROFILE_UUID:?无法从 $PROFILE_EXT 解析 UUID}"

mkdir -p Config

cat > Config/Signing.xcconfig <<EOF
#include "AppConfig.xcconfig"
// 由 scripts/gen-signing-xcconfig.sh 从 .env 生成，勿手改，勿提交（见 .gitignore）
DEVELOPMENT_TEAM = ${TEAM_ID}
APP_BUNDLE_IDENTIFIER = ${APP_BUNDLE_ID}
EXT_BUNDLE_IDENTIFIER = ${EXT_BUNDLE_ID}
APP_GROUP_ID = ${APP_GROUP}

CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = Developer ID Application
CODE_SIGN_IDENTITY[sdk=macosx*] = Developer ID Application

// Debug 开发期用自动签名（Apple Development），Developer ID 仅出包用；见 App/Ext 两个 target 各自 debug 覆盖
PROVISIONING_PROFILE_SPECIFIER_APP = ${APP_PROFILE_NAME}
PROVISIONING_PROFILE_APP = ${APP_PROFILE_UUID}
PROVISIONING_PROFILE_SPECIFIER_EXT = ${EXT_PROFILE_NAME}
PROVISIONING_PROFILE_EXT = ${EXT_PROFILE_UUID}
EOF

echo "wrote Config/Signing.xcconfig"

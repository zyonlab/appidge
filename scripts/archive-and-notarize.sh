#!/bin/sh
# scripts/archive-and-notarize.sh —— Release 归档 + 导出 + 公证 + staple。
#
# 真实跑通这个脚本需要人在 .env 里补真实的 Apple 公证凭证（Apple ID app 专用密码，
# 或者 App Store Connect API key，二选一）——这两种凭证 loop 拿不到，也不该拿到
# （同 CLAUDE.md 第 0 节的纪律：任何签名/凭证信息只从 .env 读，缺了就报错停，
# 绝不硬编码、绝不瞎猜、绝不假装跑通）。
#
# 这个脚本的职责边界：凭证齐了，就把真实的四步跑对——
#   xcodebuild archive → xcodebuild -exportArchive → xcrun notarytool submit --wait → xcrun stapler staple
# 凭证不齐，在浪费时间做一次完整 Release 归档之前就先报错停，并且清楚告诉人
# 具体缺什么变量、去哪个网页生成、填成什么样。
set -eu
cd "$(dirname "$0")/.."

note() { echo "[archive-and-notarize] $*"; }

# ---------------------------------------------------------------------------
# 0. .env 必须存在（跟 gen-signing-xcconfig.sh 同一套纪律）
# ---------------------------------------------------------------------------
[ -f .env ] || { echo "缺 .env，先从 .env.example 复制并填好" >&2; exit 1; }
set -a
. ./.env
set +a

: "${TEAM_ID:?TEAM_ID missing in .env}"
: "${APP_BUNDLE_ID:?APP_BUNDLE_ID missing in .env}"

[ -f Config/Signing.xcconfig ] || {
  echo "缺 Config/Signing.xcconfig —— 先跑 ./scripts/gen-signing-xcconfig.sh" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 0.5 自增 build 号(CURRENT_PROJECT_VERSION)——每次出包 +1。
#   为什么必须自增:系统扩展按 (short/build) 元组判新旧。build 号不变 → macOS 认为扩展没升级、
#   不把新包里的扩展换上去 → 新 app 的会话仍绑在旧扩展 / 旧 app 的 XPC 上,表现为「新包没有活动
#   连接」;app 的版本握手(运行版本 vs 包内版本)也因两边相等而永不触发重绑。自增后:macOS 正常
#   升级扩展(同团队升级无需重新批准)+ 版本握手触发重绑,活动连接恢复。
#   工程四个 build 配置共用同一个数,统一 +1;pbxproj 的改动留在工作区,由人决定何时提交。
# ---------------------------------------------------------------------------
PBXPROJ="appidge.xcodeproj/project.pbxproj"
CUR_BUILD="$(grep -m1 -oE 'CURRENT_PROJECT_VERSION = [0-9]+;' "$PBXPROJ" | grep -oE '[0-9]+' || true)"
: "${CUR_BUILD:?无法从 $PBXPROJ 读出 CURRENT_PROJECT_VERSION}"
NEXT_BUILD=$((CUR_BUILD + 1))
/usr/bin/sed -i '' -E "s/CURRENT_PROJECT_VERSION = ${CUR_BUILD};/CURRENT_PROJECT_VERSION = ${NEXT_BUILD};/g" "$PBXPROJ"
note "build 号 ${CUR_BUILD} → ${NEXT_BUILD}(每次出包自增,确保系统扩展被替换、版本握手触发重绑)"

# ---------------------------------------------------------------------------
# 1. 公证凭证：xcrun notarytool 支持两种认证方式，这里都支持，任选其一。
#    在 archive 之前就检查完，凭证不全直接报错退出，不浪费一次完整 Release 构建
#    的时间。
#
#    方式 A —— Apple ID + app 专用密码（更简单，适合个人手动跑）：
#      NOTARY_APPLE_ID                你的 Apple ID 邮箱
#      NOTARY_APP_SPECIFIC_PASSWORD   在 https://appleid.apple.com 登录后，
#                                      "登录与安全性" → "App 专用密码" 生成的
#                                      一次性密码——注意不是你的 Apple ID 登录密码
#      NOTARY_TEAM_ID                 可选，缺省时用上面已经校验过的 TEAM_ID
#
#    方式 B —— App Store Connect API key（适合 CI/自动化）：
#      NOTARY_API_KEY_PATH    下载的 .p8 私钥文件路径
#      NOTARY_API_KEY_ID      密钥 ID
#      NOTARY_API_ISSUER_ID   Issuer ID
#      三者都在 https://appstoreconnect.apple.com/access/api → Keys 页生成/查看
#      （生成密钥时 Access 选 Developer 权限即可，不需要更高权限）
# ---------------------------------------------------------------------------
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-$TEAM_ID}"

USE_API_KEY=0
USE_APPLE_ID=0
if [ -n "${NOTARY_API_KEY_PATH:-}" ] || [ -n "${NOTARY_API_KEY_ID:-}" ] || [ -n "${NOTARY_API_ISSUER_ID:-}" ]; then
  : "${NOTARY_API_KEY_PATH:?NOTARY_API_KEY_PATH missing in .env（App Store Connect API key 的 .p8 文件路径）}"
  : "${NOTARY_API_KEY_ID:?NOTARY_API_KEY_ID missing in .env（App Store Connect API key 的 Key ID）}"
  : "${NOTARY_API_ISSUER_ID:?NOTARY_API_ISSUER_ID missing in .env（App Store Connect 的 Issuer ID）}"
  [ -f "$NOTARY_API_KEY_PATH" ] || {
    echo "缺 API key 文件: $NOTARY_API_KEY_PATH（NOTARY_API_KEY_PATH 指向的路径不存在）" >&2
    exit 1
  }
  USE_API_KEY=1
elif [ -n "${NOTARY_APPLE_ID:-}" ] || [ -n "${NOTARY_APP_SPECIFIC_PASSWORD:-}" ]; then
  : "${NOTARY_APPLE_ID:?NOTARY_APPLE_ID missing in .env}"
  : "${NOTARY_APP_SPECIFIC_PASSWORD:?NOTARY_APP_SPECIFIC_PASSWORD missing in .env（appleid.apple.com 生成的 App 专用密码，不是登录密码）}"
  USE_APPLE_ID=1
else
  cat >&2 <<'MSG'
缺公证凭证。scripts/archive-and-notarize.sh 需要在 .env 里配置以下两种方式之一
（选一种填、不要两种都填半截）：

方式 A —— Apple ID + app 专用密码（更简单，适合个人手动跑）：
  NOTARY_APPLE_ID=你的AppleID邮箱
  NOTARY_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
  # 去 https://appleid.apple.com 登录 -> "登录与安全性" -> "App 专用密码" 生成
  # 注意：这不是你的 Apple ID 登录密码本身
  # NOTARY_TEAM_ID 可以不填，缺省会用 .env 里已有的 TEAM_ID

方式 B —— App Store Connect API key（适合 CI/自动化）：
  NOTARY_API_KEY_PATH=Signing/AuthKey_XXXXXXXXXX.p8
  NOTARY_API_KEY_ID=XXXXXXXXXX
  NOTARY_API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  # 去 https://appstoreconnect.apple.com/access/api -> Keys 页生成一个新密钥
  # （Access 选 Developer 权限即可），下载唯一一次给你的 .p8 私钥文件，
  # 记下页面上的 Key ID 和 Issuer ID

选一种填进 .env 再重跑这个脚本。两种凭证都不要提交进 git —— .env 已经在
.gitignore 里；如果把 .p8 文件放进这个仓库目录（比如 Signing/），确认它也没被
意外加进 git（.gitignore 目前只挡 .env 和 Config/Signing.xcconfig，如果你把
API key 放进 Signing/ 目录，检查一下要不要额外加一条 .gitignore 规则）。
MSG
  exit 1
fi

note "凭证检查通过（$( [ "$USE_API_KEY" = 1 ] && echo "App Store Connect API key 方式" || echo "Apple ID app 专用密码方式" )）"

# ---------------------------------------------------------------------------
# 2. 真实归档 + 导出 + 打包 + 公证 + staple
# ---------------------------------------------------------------------------
ARCHIVE_PATH="build/appidge.xcarchive"
EXPORT_PATH="build/export"
EXPORT_PLIST="build/ExportOptions.plist"
EXPORTED_APP="$EXPORT_PATH/appidge.app"
ZIP_PATH="$EXPORT_PATH/appidge.app.zip"

mkdir -p build

# manual 签名的 exportArchive 强制要求把每个 bundle id 显式映射到 provisioning profile 名字，
# 否则报 "requires a provisioning profile with the Network Extensions and System Extension features"
# ——即便本地 profile 完全正确，不给这个映射它也不知道该用哪个。名字从 profile 文件里解析
# （跟 gen-signing-xcconfig.sh 同一套解析）。
: "${EXT_BUNDLE_ID:?EXT_BUNDLE_ID missing in .env}"
extract_profile_name() {
  security cms -D -i "$1" 2>/dev/null | plutil -extract Name xml1 -o - - 2>/dev/null | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p'
}
APP_PROFILE_NAME="$(extract_profile_name "$PROFILE_APP")"
EXT_PROFILE_NAME="$(extract_profile_name "$PROFILE_EXT")"
: "${APP_PROFILE_NAME:?无法从 $PROFILE_APP 解析 profile 名}"
: "${EXT_PROFILE_NAME:?无法从 $PROFILE_EXT 解析 profile 名}"

note "1/5 生成 exportOptions.plist（method=developer-id，显式映射 provisioningProfiles）"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>${APP_BUNDLE_ID}</key>
		<string>${APP_PROFILE_NAME}</string>
		<key>${EXT_BUNDLE_ID}</key>
		<string>${EXT_PROFILE_NAME}</string>
	</dict>
</dict>
</plist>
PLIST

note "2/5 xcodebuild archive（Release 配置，scheme App，同时归档 App + ProxyExtension）"
xcodebuild -scheme App -configuration Release archive -archivePath "$ARCHIVE_PATH"

note "3/5 xcodebuild -exportArchive（Developer ID 导出）"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST"

[ -d "$EXPORTED_APP" ] || { echo "导出产物缺失：$EXPORTED_APP" >&2; exit 1; }

note "打包成 zip 供 notarytool 提交：$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$EXPORTED_APP" "$ZIP_PATH"

note "4/5 xcrun notarytool submit --wait（这一步会阻塞到苹果公证服务器给出结果，可能几分钟）"
if [ "$USE_API_KEY" = 1 ]; then
  xcrun notarytool submit "$ZIP_PATH" \
    --key "$NOTARY_API_KEY_PATH" \
    --key-id "$NOTARY_API_KEY_ID" \
    --issuer "$NOTARY_API_ISSUER_ID" \
    --wait
else
  xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$NOTARY_APPLE_ID" \
    --team-id "$NOTARY_TEAM_ID" \
    --password "$NOTARY_APP_SPECIFIC_PASSWORD" \
    --wait
fi

note "5/5 公证通过，staple 公证票据到 .app"
xcrun stapler staple "$EXPORTED_APP"

note "完成：$EXPORTED_APP 已归档、导出、公证并 staple，可以分发"

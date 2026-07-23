#!/bin/sh
# scripts/finish-release-staging.sh
# 续跑 staging 发布：app 已归档+公证+staple（build/export/appidge.app），本脚本只做
# DMG 公证 → EdDSA appcast → 部署 updates.appidge.com → 验证 → 还原 AppConfig。
# 全绝对路径。请在【自己的 Terminal】里跑（generate_appcast 会弹钥匙串授权，需你点“始终允许”）。
#
# ★ 前置：必须【完全退出】appidge 和 Proxifier —— 它们在拦截 timestamp.apple.com，
#   导致 codesign 报 "A timestamp was expected but was not found."。
#   确认：`systemextensionsctl list` 里 appidge / Proxifier 都不再是 activated enabled。
set -eu

REPO="/Users/admin/appidge"
WRANGLER="/Users/admin/appidge/apps/api/node_modules/.bin/wrangler"
GEN_APPCAST="/Users/admin/Library/Developer/Xcode/DerivedData/appidge-afvulpcmatefggdpoawebmbxyles/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
[ -x "$GEN_APPCAST" ] || GEN_APPCAST="$(/usr/bin/find "$HOME/Library/Developer/Xcode/DerivedData" -name generate_appcast -type f 2>/dev/null | /usr/bin/head -1)"

set -a; . "$REPO/.env"; set +a

echo "===[0/5] 预检：真实做一次带时间戳的 codesign（比 curl 靠谱）==="
PROBE_DIR="$(/usr/bin/mktemp -d)"; /bin/cp /bin/echo "$PROBE_DIR/probe"
if ! /usr/bin/codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$PROBE_DIR/probe" 2>"$PROBE_DIR/err"; then
  echo "❌ 安全时间戳签名失败 —— appidge / Proxifier 代理仍在拦截 timestamp.apple.com。" >&2
  echo "   请【完全退出】两者（systemextensionsctl list 里都不再 activated enabled），再跑本脚本。" >&2
  /bin/cat "$PROBE_DIR/err" >&2; exit 1
fi
echo "✅ 安全时间戳可用"

echo "===[1/5] 打包 + 公证 + staple DMG ==="
/bin/sh "$REPO/scripts/make-dmg.sh"

echo "===[2/5] 生成 EdDSA 签名 appcast —— 弹钥匙串授权时请点【始终允许 / Always Allow】==="
/bin/rm -rf "$REPO/build/appcast"; /bin/mkdir -p "$REPO/build/appcast"
/bin/cp "$REPO"/build/appidge-*.dmg "$REPO/build/appcast/"
"$GEN_APPCAST" "$REPO/build/appcast" --download-url-prefix "https://updates.appidge.com/"

echo "===[3/5] 部署 updates.appidge.com（Workers 静态资源）==="
/bin/rm -rf "$REPO/infra/updates/public"; /bin/mkdir -p "$REPO/infra/updates/public"
/bin/cp "$REPO"/build/appcast/appcast.xml "$REPO"/build/appcast/*.dmg "$REPO/infra/updates/public/"
# 官网「下载 App」按钮指向稳定文件名，随每次发布刷新为最新 DMG。
/bin/cp "$REPO"/build/appcast/*.dmg "$REPO/infra/updates/public/appidge-latest.dmg"
( cd "$REPO/infra/updates" && "$WRANGLER" deploy --env staging )

echo "===[4/5] 验证 ==="
/usr/bin/curl -sI -m 15 https://updates.appidge.com/appcast.xml | /usr/bin/head -1
/usr/bin/grep -oE 'sparkle:version="[^"]+"|url="[^"]+\.dmg"|length="[^"]+"' "$REPO/build/appcast/appcast.xml" || true

echo "===[5/5] 还原 AppConfig 为 prod 默认 ==="
cat > "$REPO/Config/AppConfig.xcconfig" <<'PRODEOF'
// Config/AppConfig.xcconfig
// 非秘密、已提交的应用运行期配置。可按环境覆盖:直接改本文件、用另一个 xcconfig include 覆盖,
// 或构建期传 `xcodebuild LICENSE_API_BASE_URL=... build`。
// 这里不放任何签名信息或密钥(那些在 git-ignore 的 Config/Signing.xcconfig)。
//
// 注意:空赋值仍然 *定义* 变量,使 Info.plist 里的 $(VAR) 展开成空字符串,而不是字面量 token。
// 写作 `VAR = ` (等号后什么都不跟)。

// License facade · Worker API base URL。
// 空 = Swift 层安全回退到本地开发地址 http://127.0.0.1:8787。
// staging: https://api-staging.appidge.com
// prod:    https://api.appidge.com
LICENSE_API_BASE_URL =

// 购买许可证 · Polar Hosted Checkout Link。
// 空 = 隐藏 App 内购买入口,直到配置好为止。
LICENSE_CHECKOUT_URL =

// Sparkle 自动升级 appcast feed 地址。
// 默认 = prod,保持当前发布行为不变。
// staging 覆盖: https://updates.appidge.com/appcast.xml
// 注意:xcconfig 把 `//` 当行注释起点,URL 里的双斜杠会被吞掉;用空展开 $() 隔断两个斜杠,
//       展开后仍是 https://updates.appidge.com/appcast.xml。命令行 xcodebuild VAR=... 覆盖不受此限。
SPARKLE_FEED_URL = https:/$()/updates.appidge.com/appcast.xml
// 让编译器把 SwiftUI 本地化字符串提取/合并进 catalog（IDE 构建自动同步；防新串回退成中文源）。
SWIFT_EMIT_LOC_STRINGS = YES
PRODEOF
echo "=== DONE：updates.appidge.com 已上线 appcast + DMG，AppConfig 已还原 prod ==="

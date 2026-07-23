#!/bin/sh
# scripts/release-staging.sh
# 出 staging 更新包（signed+notarized DMG + EdDSA appcast）并部署到 updates.appidge.com。
# 全绝对路径，可在任意 cwd 下 `sh /Users/admin/appidge/scripts/release-staging.sh` 直接跑。
#
# 前置（重要）：Developer ID 签名/公证要联网到苹果服务器盖时间戳。
#   先退出 appidge / Proxifier 代理（或给 timestamp.apple.com、notary-api.apple.com 加直连规则），
#   否则会卡在 codesign "A timestamp was expected but was not found."。脚本第 0 步会先预检。
set -eu

REPO="/Users/admin/appidge"
WRANGLER="/Users/admin/appidge/apps/api/node_modules/.bin/wrangler"
GEN_APPCAST="/Users/admin/Library/Developer/Xcode/DerivedData/appidge-afvulpcmatefggdpoawebmbxyles/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
[ -x "$GEN_APPCAST" ] || GEN_APPCAST="$(/usr/bin/find "$HOME/Library/Developer/Xcode/DerivedData" -name generate_appcast -type f 2>/dev/null | /usr/bin/head -1)"

echo "===[0/6] 写入 staging AppConfig + 预检安全时间戳（真做一次 codesign，比 curl 靠谱）==="
set -a; . "$REPO/.env"; set +a
cat > "$REPO/Config/AppConfig.xcconfig" <<'STGEOF'
// Config/AppConfig.xcconfig — 临时 STAGING 覆盖（出 staging 包用；整条成功后脚本第 6 步还原 prod）。
LICENSE_API_BASE_URL = https:/$()/api-staging.appidge.com
LICENSE_CHECKOUT_URL = https:/$()/sandbox-api.polar.sh/v1/checkout-links/polar_cl_BBKSC5KnwGuFO1aqPPSO6O8TAW16C3oFGy5uf0zgDRJ/redirect
SPARKLE_FEED_URL = https:/$()/updates.appidge.com/appcast.xml
// 让编译器把 SwiftUI 本地化字符串提取/合并进 catalog（IDE 构建自动同步；防新串回退成中文源）。
SWIFT_EMIT_LOC_STRINGS = YES
STGEOF
PROBE_DIR="$(/usr/bin/mktemp -d)"; /bin/cp /bin/echo "$PROBE_DIR/probe"
if ! /usr/bin/codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$PROBE_DIR/probe" 2>"$PROBE_DIR/err"; then
  echo "❌ 安全时间戳签名失败 —— appidge/Proxifier 代理仍在拦截 timestamp.apple.com。" >&2
  echo "   请【完全退出】两者后再跑本脚本。" >&2
  /bin/cat "$PROBE_DIR/err" >&2; exit 1
fi
echo "✅ staging 配置已写入，安全时间戳可用"

echo "===[1/6] 清理旧 DMG ==="
/bin/rm -f "$REPO"/build/appidge-*.dmg 2>/dev/null || true

echo "===[2/6] 归档 + 公证 app（自增 build 号，约几分钟）==="
/bin/sh "$REPO/scripts/archive-and-notarize.sh"

echo "===[3/6] 打包 + 公证 DMG ==="
/bin/sh "$REPO/scripts/make-dmg.sh"

echo "===[4/6] 生成 EdDSA 签名 appcast（私钥在登录钥匙串）==="
/bin/rm -rf "$REPO/build/appcast"; /bin/mkdir -p "$REPO/build/appcast"
/bin/cp "$REPO"/build/appidge-*.dmg "$REPO/build/appcast/"
"$GEN_APPCAST" "$REPO/build/appcast" --download-url-prefix "https://updates.appidge.com/"

echo "===[5/6] 部署到 updates.appidge.com（Workers 静态资源）==="
/bin/rm -rf "$REPO/infra/updates/public"; /bin/mkdir -p "$REPO/infra/updates/public"
/bin/cp "$REPO"/build/appcast/appcast.xml "$REPO"/build/appcast/*.dmg "$REPO/infra/updates/public/"
# 官网「下载 App」按钮指向稳定文件名，随每次发布刷新为最新 DMG。
/bin/cp "$REPO"/build/appcast/*.dmg "$REPO/infra/updates/public/appidge-latest.dmg"
( cd "$REPO/infra/updates" && "$WRANGLER" deploy --env staging )

echo "===[6/6] 验证 + 还原 AppConfig 为 prod 默认 ==="
/usr/bin/curl -sI -m 15 https://updates.appidge.com/appcast.xml | /usr/bin/head -1
/usr/bin/grep -oE 'sparkle:version="[^"]+"|url="[^"]+\.dmg"' "$REPO/build/appcast/appcast.xml" || true
# 只在整条成功后还原（中途失败会保留 staging 配置供重试）
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

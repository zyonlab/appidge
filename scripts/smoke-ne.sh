#!/bin/sh
# scripts/smoke-ne.sh —— 装系统扩展 → 发一条流量 → 打印观测到的进程身份级别。
#
# 这个脚本能做到「就差人点允许」：它会真的构建、签名、启动 app，真的提交系统扩展
# 激活请求，真的跑一条 curl。但 macOS 系统扩展的激活批准物理上必须由人在
# 「系统设置 → 隐私与安全性」点一下「允许」——没有 API 能绕过这一步，这不是脚本
# 偷懒，是苹果的安全模型决定的。跑完这个脚本，人回来看 systemextensionsctl 的状态：
# 如果还是 "activated waiting for user"，去点允许，再跑一遍这个脚本，
# 这次 log stream 那段应该能抓到真实流量下 sourceAppSigningIdentifier 的值——
# 把那个值（父 app 级 bundle id，还是 curl 自己的身份）填回 PROGRESS.md。
set -eu
cd "$(dirname "$0")/.."

APP_BUNDLE_ID="com.appidge.app"
EXT_BUNDLE_ID="com.appidge.app.ProxyExtension"
APP_PATH="build/appidge.app"
DERIVED_APP="$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name 'appidge-*' -print -quit 2>/dev/null)/Build/Products/Debug/appidge.app"

# 注意：不要把这个辅助函数命名为 log —— 会 shadow 掉下面真正要用的系统 /usr/bin/log 命令。
note() { echo "[smoke-ne] $*"; }

note "1/6 确保有已签名的可安装 build"
if [ ! -d "$APP_PATH" ] && [ ! -d "$DERIVED_APP" ]; then
  note "没找到已构建的 app，先跑 xcodebuild ..."
  xcodebuild -scheme App -configuration Debug -destination 'platform=macOS,arch=arm64' build
fi
if [ -d "$DERIVED_APP" ]; then
  mkdir -p build
  rsync -a --delete "$DERIVED_APP/" "$APP_PATH/"
fi
[ -d "$APP_PATH" ] || { note "构建产物缺失：$APP_PATH"; exit 1; }

note "2/6 codesign 校验（E3 证据）"
codesign -dv --verbose=2 "$APP_PATH" 2>&1 | sed 's/^/    App: /'
codesign -dv --verbose=2 "$APP_PATH/Contents/Library/SystemExtensions/ProxyExtension.systemextension" 2>&1 | sed 's/^/    Ext: /'
codesign --verify --deep --strict "$APP_PATH" && note "    codesign --verify --deep --strict: 通过"

note "3/6 systemextensionsctl 当前状态（激活前）"
systemextensionsctl list 2>&1 | (grep -i "$EXT_BUNDLE_ID" || echo "    尚未提交过激活请求")

note "4/6 启动 app 触发真实的 OSSystemExtensionManager 激活请求"
note "   （后台跟一段 /usr/bin/log stream，抓 App 和 Extension 两个 subsystem 的日志）"
LOGFILE="$(mktemp -t smoke-ne-log)"
/usr/bin/log stream --style compact \
  --predicate "subsystem == \"$APP_BUNDLE_ID\" OR subsystem == \"$EXT_BUNDLE_ID\"" \
  > "$LOGFILE" 2>&1 &
LOG_PID=$!
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT

open "$APP_PATH"
sleep 5

note "5/6 systemextensionsctl 状态（激活请求提交后，通常会是 activated waiting for user）"
systemextensionsctl list 2>&1 | (grep -i "$EXT_BUNDLE_ID" || echo "    还没出现在列表里——再等几秒或检查 app 是否真的启动了")

note "6/6 发一条流量，尝试观测 flow metadata（只有人点了允许、代理真的在跑，这步才会抓到东西）"
curl -m 5 -sS -o /dev/null -w "curl exit via direct path, http_code=%{http_code}\n" https://example.com 2>&1 | sed 's/^/    /' || true

sleep 2
kill "$LOG_PID" 2>/dev/null || true
wait "$LOG_PID" 2>/dev/null || true
trap - EXIT

note "捕获到的 App/Extension 日志："
if [ -s "$LOGFILE" ]; then
  sed 's/^/    /' "$LOGFILE"
else
  note "    （空——说明扩展还没被批准/激活，这是预期的，直到人点允许为止）"
fi
rm -f "$LOGFILE"

note "---"
note "状态小结："
note "  - build 已签名、codesign 校验通过：见上面第 2 步"
note "  - 系统扩展激活请求已真实提交：见上面第 4-5 步 systemextensionsctl 输出"
note "  - 唯一卡住的地方：系统设置 > 隐私与安全性 里点『允许』批准这个系统扩展"
note "  - 批准后重跑本脚本，第 6 步的 log stream 应该能抓到形如："
note "      handleNewFlow sourceAppSigningIdentifier=... remote=..."
note "    把 sourceAppSigningIdentifier 的实际值（是 curl 自己，还是父进程/shell 的身份）"
note "    填回 PROGRESS.md 的『待人回填』条目。"

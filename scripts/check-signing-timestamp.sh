#!/bin/sh
# scripts/check-signing-timestamp.sh —— 出包前的签名时间戳可达性探针。
#
# 为什么需要它：appidge 是全接管透明代理，会把**自己的签名/公证链路**也拦下来。
# codesign 取安全时间戳要连 timestamp.apple.com，经代理后时好时坏，表现为
# xcodebuild archive 跑了好几分钟才死在：
#     "A timestamp was expected but was not found."
# 用 curl 探测不可靠（HTTP 通不代表 codesign 的时间戳事务能成），
# 所以这里**真做一次带时间戳的签名**，再用 --timestamp=none 做对照组，
# 把「网络/代理问题」与「证书/身份问题」区分开。
#
# 退出码：0 = 可以出包；1 = 时间戳不可达（附处置步骤）；2 = 环境/凭证问题。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

[ -f .env ] || { echo "缺 .env（签名身份从这里读）" >&2; exit 2; }
set -a
. ./.env
set +a
: "${DEVELOPER_ID_APPLICATION:?DEVELOPER_ID_APPLICATION missing in .env}"

# 探针对象要用**我们自己签过的 Mach-O**，别用 /bin/* 系统二进制——
# 那会引入「苹果系统二进制不让重签」的混淆因素，读不准。
PROBE_SRC=""
for cand in "build/export/appidge.app/Contents/MacOS/appidge" "$(command -v codesign)"; do
  [ -f "$cand" ] && { PROBE_SRC=$cand; break; }
done
[ -n "$PROBE_SRC" ] || { echo "找不到可用的探针二进制" >&2; exit 2; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT INT TERM
cp "$PROBE_SRC" "$TMPD/probe"

echo "[timestamp-probe] 探针对象：$PROBE_SRC"

# 对照组：不要时间戳。这一步失败 = 证书/身份/Keychain 问题，与代理无关。
if ! ctl=$(codesign --force --options runtime --timestamp=none \
             --sign "$DEVELOPER_ID_APPLICATION" "$TMPD/probe" 2>&1); then
  echo "[timestamp-probe] ✗ 连不带时间戳的签名都失败了——这不是代理问题，是签名身份/Keychain 问题：" >&2
  printf '%s\n' "$ctl" | sed "s|$TMPD|<tmp>|g" >&2
  exit 2
fi

# 实验组：带时间戳。失败即代理拦了 timestamp.apple.com。
if out=$(codesign --force --options runtime --timestamp \
           --sign "$DEVELOPER_ID_APPLICATION" "$TMPD/probe" 2>&1); then
  echo "[timestamp-probe] ✓ 带时间戳签名成功——可以出包"
  exit 0
fi

echo "[timestamp-probe] ✗ 带时间戳签名失败（不带时间戳是成功的 ⇒ 坏的就是时间戳网络往返）：" >&2
printf '%s\n' "$out" | sed "s|$TMPD|<tmp>|g" >&2
echo >&2
echo "处置：完整退出 appidge 与 Proxifier，然后重跑本探针。" >&2
echo "  ⚠️ 只「停止接管」不够；两者在 systemextensionsctl list 里都不能是 activated。" >&2
echo "  ⚠️ 别用 kill 杀网络扩展进程——会话会绑死在已死的 provider 上，全系统断网。走 App 自己的退出流程。" >&2
echo >&2
echo "当前仍在接管的扩展：" >&2
systemextensionsctl list 2>/dev/null \
  | grep -iE "appidge|proxifier" | grep -i "activated enabled" | sed 's/^/  /' >&2 || true
exit 1

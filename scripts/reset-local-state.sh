#!/bin/sh
# 清空本机 appidge 的所有用户态数据，用于「全新安装」路径测试
# （首启引导 → 7 天试用重新计时 → 授权激活 → 规则/代理从零开始）。
#
# 默认 **dry-run**：只列出会删什么，不动手。真正删除要显式 --apply（同 ops/bin/appidge-ops 的惯例）。
#
#   sh scripts/reset-local-state.sh                # 看会删什么
#   sh scripts/reset-local-state.sh --apply        # 全清（模拟全新安装）
#   sh scripts/reset-local-state.sh --trial-only --apply   # 只重置 7 天试用锚点
#
# ⚠️ 有两样东西**脚本删不了**，见结尾提示：系统网络设置里的透明代理配置、已安装的系统扩展。
#    它们是系统级的，直接删对应 plist 会连带破坏其它 app（如 Proxifier）的 VPN 配置——绝不这么做。
set -eu

APPLY=0
TRIAL_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --trial-only) TRIAL_ONLY=1 ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "未知选项：${arg}（--apply / --trial-only / --help）" >&2; exit 2 ;;
  esac
done

note() { printf '[reset-state] %s\n' "$1"; }
act()  { if [ "$APPLY" = 1 ]; then printf '  \033[31m删除\033[0m %s\n' "$1"; else printf '  [dry-run] 会删 %s\n' "$1"; fi; }
skip() { printf '  \033[90m跳过\033[0m %s（不存在）\n' "$1"; }

APP_ID="com.appidge.app"
APP_GROUP="group.com.appidge"
SUPPORT="$HOME/Library/Application Support/appidge"   # 大小写不敏感：TrialInfra 写的 Appidge/ 是同一处

# ---------------------------------------------------------------------------
# 0. 先退出 app —— 否则它退出时会把内存里的配置**同步存盘**（applicationWillTerminate →
#    AppTermination.persist），把刚删掉的 config.json 原样写回来，清空等于白做。
# ---------------------------------------------------------------------------
if pgrep -x appidge >/dev/null 2>&1; then
  if [ "$APPLY" = 1 ]; then
    note "appidge 正在运行 —— 先退出（它退出时会同步存盘，不退就会把配置写回来）"
    osascript -e 'quit app "appidge"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -x appidge >/dev/null 2>&1 || break
      sleep 1
    done
    pgrep -x appidge >/dev/null 2>&1 && { echo "appidge 未能退出，请手动退出后重跑" >&2; exit 1; }
    note "已退出"
  else
    note "⚠️ appidge 正在运行 —— --apply 时会先自动退出它（必须，否则退出时存盘会写回配置）"
  fi
fi

# ---------------------------------------------------------------------------
# 1. 试用双锚点（TrialAnchorStore 的两处冗余：删一处不够，判定取两者最早）
# ---------------------------------------------------------------------------
note "试用锚点（双冗余——两处都要删，否则仍判定「已开始试用」）"
if [ -f "$SUPPORT/trial-anchor.json" ]; then
  act "$SUPPORT/trial-anchor.json"
  if [ "$APPLY" = 1 ]; then rm -f "$SUPPORT/trial-anchor.json"; fi
else
  skip "$SUPPORT/trial-anchor.json"
fi
if security find-generic-password -s "com.appidge.trial" >/dev/null 2>&1; then
  act "钥匙串 com.appidge.trial"
  if [ "$APPLY" = 1 ]; then security delete-generic-password -s "com.appidge.trial" >/dev/null 2>&1 || true; fi
else
  skip "钥匙串 com.appidge.trial"
fi

if [ "$TRIAL_ONLY" = 1 ]; then
  echo
  note "--trial-only：仅重置试用锚点，其余保留。重开 app 即重新开始 7 天计时。"
  if [ "$APPLY" != 1 ]; then note "这是 dry-run —— 加 --apply 才真的删。"; fi
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. 钥匙串：授权记录 + 代理密码
# ---------------------------------------------------------------------------
echo
note "钥匙串条目"
for svc in com.appidge.license com.appidge.proxy-credentials; do
  if security find-generic-password -s "$svc" >/dev/null 2>&1; then
    act "钥匙串 $svc"
    if [ "$APPLY" = 1 ]; then
      # 同一 service 可能有多条（多台代理各一条密码），循环删到没有为止。
      while security find-generic-password -s "$svc" >/dev/null 2>&1; do
        security delete-generic-password -s "$svc" >/dev/null 2>&1 || break
      done
    fi
  else
    skip "钥匙串 $svc"
  fi
done

# ---------------------------------------------------------------------------
# 3. 配置 / 日志 / 档案（Application Support）
# ---------------------------------------------------------------------------
echo
note "配置与日志"
if [ -d "$SUPPORT" ]; then
  act "$SUPPORT/（config.json · profiles.json · connections.log.jsonl）"
  if [ "$APPLY" = 1 ]; then rm -rf "$SUPPORT"; fi
else
  skip "$SUPPORT/"
fi

# ---------------------------------------------------------------------------
# 4. App Group 容器（扩展诊断日志 ExtDiag、抓包 captures/*.dmp）
# ---------------------------------------------------------------------------
echo
note "App Group 容器（扩展诊断 + 抓包）"
GC="$HOME/Library/Group Containers/$APP_GROUP"
if [ -d "$GC" ]; then
  act "$GC/"
  if [ "$APPLY" = 1 ]; then rm -rf "$GC"; fi
else
  skip "$GC/"
fi

# ---------------------------------------------------------------------------
# 5. 偏好设置（含首启引导标记、界面语言、Sparkle 检查更新状态）
# ---------------------------------------------------------------------------
echo
note "偏好设置与缓存"
if defaults read "$APP_ID" >/dev/null 2>&1; then
  act "UserDefaults 域 ${APP_ID}（引导标记 / 界面语言 / Sparkle 状态）"
  if [ "$APPLY" = 1 ]; then
    defaults delete "$APP_ID" >/dev/null 2>&1 || true
    # cfprefsd 会缓存已删的域，不 kill 的话重开 app 可能读到旧值。
    killall cfprefsd >/dev/null 2>&1 || true
  fi
else
  skip "UserDefaults 域 $APP_ID"
fi
for d in "$HOME/Library/Caches/$APP_ID" \
         "$HOME/Library/HTTPStorages/$APP_ID" \
         "$HOME/Library/Saved Application State/$APP_ID.savedState" \
         "$HOME/Library/Preferences/$APP_ID.plist"; do
  if [ -e "$d" ]; then
    act "$d"
    if [ "$APPLY" = 1 ]; then rm -rf "$d"; fi
  else
    skip "$d"
  fi
done

# ---------------------------------------------------------------------------
# 6. 脚本删不了的两样 —— 必须人工，且不能用「删 plist」的粗暴办法
# ---------------------------------------------------------------------------
echo
note "以下两项脚本不处理，需人工（原因见下）："
cat <<'MANUAL'
  ① 系统网络设置里的透明代理配置
     appidge 内：设置 → 网络接管 → 「重置（移除代理配置）」。
     为什么不脚本删：这份配置存在系统级 /Library/Preferences/com.apple.networkextension.plist，
     里面同时住着其它 app（如 Proxifier）的 VPN/代理配置，整文件删会一并破坏它们。
     真正干净的做法是走 app 内的 NEVPNManager.removeFromPreferences()，也就是那个按钮。
     ⚠️ 想测「首次弹『appidge 想添加 VPN/代理配置』授权」这一步，就必须先点它。

  ② 已安装的系统扩展（com.appidge.app.ProxyExtension）
     查看： systemextensionsctl list | grep appidge
     卸载： 把 /Applications/appidge.app 拖进废纸篓 → 重启 Mac
     为什么不脚本删：systemextensionsctl uninstall 在未开启开发者模式的机器上会被拒；
     而旧扩展本来就要重启后才真正卸载（列表里的 "waiting to uninstall on reboot" 即此）。
     ⚠️ 想测「首次弹系统扩展批准」这一步，必须走这条路并重启。
MANUAL

echo
if [ "$APPLY" = 1 ]; then
  note "已清空。重开 app 应表现为全新安装：首启引导 → 试用重新计时 7 天 → 未授权。"
else
  note "以上是 dry-run，什么都没删。确认无误后加 --apply。"
fi

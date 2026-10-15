#!/bin/bash
# smartroute 卸载脚本 —— 目标：卸完不留任何痕迹
#
# 用法：
#   sudo bash uninstall.sh             # 交互式（会问你一句要不要删 App）
#   sudo bash uninstall.sh --yes       # 全删，不提问
#   sudo bash uninstall.sh --dry-run   # 只列出会删什么，不动手
#   sudo bash uninstall.sh --keep-logs # 保留日志
#
# 会清理：
#   1. launchd 守护进程（停止 + 删 plist）
#   2. pf 分流规则（刷掉 com.apple/smartroute 锚点 + 删锚点文件）
#      如果系统 pf 是我们打开的，就连 pf 一起关掉
#   3. 探测用的临时主机路由
#   4. 命令行工具 /usr/local/bin/smartroute
#   5. 全部配置文件（/etc 与 /Users/Shared，含 .tmp/.rules 残留）
#   6. 状态目录、日志、锁文件、/tmp 探测残留
#   7. App 本体 /Applications/SmartRoute.app（默认删，可保留）
set -u

YES=0; DRY=0; KEEP_LOGS=0
for a in "$@"; do
    case "$a" in
        -y|--yes) YES=1 ;;
        -n|--dry-run) DRY=1 ;;
        --keep-logs) KEEP_LOGS=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数: $a（用 --help 看用法）" >&2; exit 1 ;;
    esac
done

C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_B=$'\033[1;36m'; C_0=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '    %s⚠%s %s\n' "$C_Y" "$C_0" "$*"; }
skip() { printf '    %s-%s %s（本来就没有）\n' "$C_0" "$C_0" "$*"; }

# 统一执行/预览：run <描述> <命令...>
run() {
    local desc="$1"; shift
    if [ "$DRY" = "1" ]; then printf '    %s·%s 将删除: %s\n' "$C_0" "$C_0" "$desc"; return 0; fi
    if "$@" >/dev/null 2>&1; then ok "$desc"; else warn "$desc（失败，可忽略）"; fi
}

# 需要 root：pfctl/route/删系统文件都要
if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行：sudo bash uninstall.sh"
    exit 1
fi

echo
say "SmartRoute 卸载（dry-run=$DRY 保留日志=$KEEP_LOGS）"
echo

# ---------- 0. 先停守护进程（否则它会把规则/路由又写回来） ----------
say "停止守护进程"
if [ "$DRY" = "1" ]; then
    printf '    %s·%s 将 bootout/unload com.user.smartroute，并杀掉残留 watch 进程\n' "$C_0" "$C_0"
elif launchctl bootout system/com.user.smartroute >/dev/null 2>&1; then ok "已 bootout（现代方式）"
elif launchctl unload /Library/LaunchDaemons/com.user.smartroute.plist >/dev/null 2>&1; then ok "已 unload（旧方式）"
else skip "守护进程未在运行"; fi
# 双保险：按名字杀（watch 模式）
if [ "$DRY" = "0" ]; then
    pkill -f "smartroute watch" >/dev/null 2>&1 && ok "已杀掉残留 watch 进程" || true
fi

# ---------- 1. pf 分流规则 ----------
say "清理 pf 分流规则"
ANCHOR="com.apple/smartroute"
if [ "$DRY" = "0" ]; then
    if pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -q .; then
        pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1 && ok "已刷掉锚点 $ANCHOR 内的规则" || warn "刷规则失败"
    else
        skip "锚点内没有规则"
    fi
    # 我们打开的 pf 要关掉；用户自己开的别动
    if [ -f /var/db/smartroute/pf.state ] && grep -q "pf_enabled_by_us=1" /var/db/smartroute/pf.state 2>/dev/null; then
        pfctl -d >/dev/null 2>&1 && ok "系统 pf 由我们打开，已关闭" || warn "关闭 pf 失败"
    fi
else
    printf '    %s·%s 将刷掉锚点 %s 的规则；若是我们开的 pf 就连 pf 一起关\n' "$C_0" "$C_0" "$ANCHOR"
fi
run "锚点文件 /etc/pf.anchors/com.user.smartroute" rm -f /etc/pf.anchors/com.user.smartroute

# ---------- 2. 探测用的临时主机路由 ----------
say "清理临时主机路由"
if [ "$DRY" = "0" ]; then
    n=0
    for t in 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 208.67.222.222 223.5.5.5 114.114.114.114; do
        route delete -host "$t" >/dev/null 2>&1 && n=$((n+1))
    done
    [ "$n" -gt 0 ] && ok "删了 $n 条探测主机路由" || skip "没有残留的探测路由"
else
    printf '    %s·%s 将删除探测用的 -host 路由（若存在）\n' "$C_0" "$C_0"
fi

# ---------- 3. 程序与配置 ----------
say "删除程序与配置"
run "命令行工具 /usr/local/bin/smartroute"       rm -f /usr/local/bin/smartroute
run "守护进程 plist"                             rm -f /Library/LaunchDaemons/com.user.smartroute.plist
run "系统配置 /etc/smartroute.conf"              rm -f /etc/smartroute.conf
run "用户配置 /Users/Shared/smartroute.conf"     rm -f /Users/Shared/smartroute.conf
run "用户配置临时残留 .conf.tmp*"                bash -c 'rm -f /Users/Shared/smartroute.conf.tmp*'
run "分流规则 /Users/Shared/smartroute.rules"    rm -f /Users/Shared/smartroute.rules
run "状态目录 /var/db/smartroute"                rm -rf /var/db/smartroute
run "锁目录 /var/run/smartroute.lock"            rm -rf /var/run/smartroute.lock
run "/tmp 探测残留"                              bash -c 'rm -f /tmp/.smartroute.probe.*'
if [ "$KEEP_LOGS" = "1" ]; then
    warn "按要求保留日志：/var/log/smartroute.{log,out,err}"
else
    run "日志 /var/log/smartroute.log"            rm -f /var/log/smartroute.log
    run "守护进程 stdout /var/log/smartroute.out" rm -f /var/log/smartroute.out
    run "守护进程 stderr /var/log/smartroute.err" rm -f /var/log/smartroute.err
fi

# ---------- 4. App 本体 ----------
say "App 本体"
APP="/Applications/SmartRoute.app"
if [ -d "$APP" ]; then
    if [ "$DRY" = "1" ]; then
        printf '    %s·%s 将删除 %s\n' "$C_0" "$C_0" "$APP"
    elif [ "$YES" = "1" ]; then
        rm -rf "$APP" && ok "已删除 $APP" || warn "删除 App 失败"
    else
        printf '    删除 %s ？[y/N] ' "$APP"
        read -r ans
        case "$ans" in
            y|Y|yes) rm -rf "$APP" && ok "已删除 $APP" || warn "删除 App 失败" ;;
            *) warn "保留 $APP（可随时自己拖进废纸篓）" ;;
        esac
    fi
else
    skip "$APP"
fi

# ---------- 5. 校验：真的没留东西吗 ----------
if [ "$DRY" = "0" ]; then
    echo
    say "校验残留"
    left=0
    for f in /usr/local/bin/smartroute /Library/LaunchDaemons/com.user.smartroute.plist \
             /etc/smartroute.conf /Users/Shared/smartroute.conf /Users/Shared/smartroute.rules \
             /etc/pf.anchors/com.user.smartroute /var/db/smartroute /var/run/smartroute.lock \
             "$APP"; do
        if [ -e "$f" ] || [ -L "$f" ]; then printf '    %s✗%s 仍在: %s\n' "$C_R" "$C_0" "$f"; left=$((left+1)); fi
    done
    if [ "$KEEP_LOGS" != "1" ]; then
        for f in /var/log/smartroute.log /var/log/smartroute.out /var/log/smartroute.err; do
            [ -e "$f" ] && { printf '    %s✗%s 仍在: %s\n' "$C_R" "$C_0" "$f"; left=$((left+1)); }
        done
    fi
    if ls /tmp/.smartroute.probe.* >/dev/null 2>&1; then
        printf '    %s✗%s /tmp 仍有探测残留\n' "$C_R" "$C_0"; left=$((left+1))
    fi
    if pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -q .; then
        printf '    %s✗%s pf 锚点里仍有规则\n' "$C_R" "$C_0"; left=$((left+1))
    fi
    if pgrep -f "smartroute watch" >/dev/null 2>&1; then
        printf '    %s✗%s watch 进程仍在运行\n' "$C_R" "$C_0"; left=$((left+1))
    fi

    if [ "$left" -eq 0 ]; then
        printf '    %s✅ 零残留：所有文件、规则、路由、进程都已清干净%s\n' "$C_G" "$C_0"
    else
        printf '    %s还有 %d 项残留（见上），可重跑一次或手动处理%s\n' "$C_Y" "$left" "$C_0"
    fi
    echo
    say "卸载完成。网络设置未改动，当前路由/pf 保持原样。"
else
    echo
    say "dry-run 结束，未做任何改动。去掉 --dry-run 正式执行。"
fi
echo

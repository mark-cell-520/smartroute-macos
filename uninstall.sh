#!/bin/bash
# smartroute 卸载脚本 —— 目标：卸完不留任何痕迹
#
# 用法：
#   sudo bash uninstall.sh             # 交互式（会问你一句要不要删 App）
#   sudo bash uninstall.sh --yes       # 全删，不提问
#   sudo bash uninstall.sh --dry-run   # 只列出会删什么，不动手
#   sudo bash uninstall.sh --keep-logs # 保留日志
#   sudo bash uninstall.sh --keep-app  # 保留 App 本体（App 内调用卸载时必须加，
#                                      # 否则会把正在运行的 App 一起删掉）
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

YES=0; DRY=0; KEEP_LOGS=0; KEEP_APP=0
for a in "$@"; do
    case "$a" in
        -y|--yes) YES=1 ;;
        -n|--dry-run) DRY=1 ;;
        --keep-logs) KEEP_LOGS=1 ;;
        --keep-app) KEEP_APP=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数: ${a}（用 --help 看用法）" >&2; exit 1 ;;
    esac
done

# 只在真终端里上色。经 App 的 do shell script 调到这里时 stdout 是管道、
# 不是 tty，此时若还发 ANSI 转义符，\033[1;32m 会原样进 SwiftUI 的 Text，
# 用户看到一串乱码。install.sh 早有这个判断，这里补上。
if [ -t 1 ]; then
    C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_B=$'\033[1;36m'; C_0=$'\033[0m'
else
    C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""
fi
say()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '    %s⚠%s %s\n' "$C_Y" "$C_0" "$*"; }
skip() { printf '    %s-%s %s（本来就没有）\n' "$C_0" "$C_0" "$*"; }

# 统一执行/预览：run <描述> <命令...>
# 失败时不再说"（失败，可忽略）"——那句话会把用户训练成忽视失败，
# 而卸载是他对工具信任最脆弱的时刻，满屏 ⚠ 反而更慌：到底哪个要紧？
# 改成给出可以照抄的手动命令，让他自己能收尾。
# 第二个参数：目标路径。给了它才能区分"删掉了"和"本来就不在"。
# 以前只要 rm 成功就打 ✓。而 rm 对不存在的文件也返回 0——于是重复卸载时
# （第一次删干净了，用户不放心再跑一次）会看到满屏 ✓ "已删除"，
# 每一个都是假的。用户无法从输出判断这次到底删了什么。
# 传 "-" 表示"这个命令没有单一目标路径"，跳过存在性判断。
# 必须有这个逃生口：像"遍历所有用户的 LaunchAgents 再删"这类循环命令
# 没有单一目标，硬塞一个路径只会得到错误的"已不在"。
run() {
    local desc="$1"; shift
    local target="${1:-}"
    # 两种取值都要 shift：target="-" 是逃生口（无单一目标），target=路径是正常用法。
    # 只把 target 置空却不 shift 的话，"-" 会留在 "$@" 里被当成命令执行。
    if [ "$target" = "-" ]; then target=""; shift
    elif [ -n "$target" ]; then shift; fi
    if [ "$DRY" = "1" ]; then printf '    %s·%s 将删除: %s\n' "$C_0" "$C_0" "$desc"; return 0; fi
    # 存在性必须在删除**之前**判断。写成删完之后再查是错的：删成功的话目标
    # 当然不在了，那正是成功的标志，却被当成"上次已删"——于是第一次卸载也
    # 满屏"已不在"，比原来的假 ✓ 更糟（连真的删掉了都不承认）。
    local existed=1
    if [ -n "$target" ] && [ ! -e "$target" ] && [ ! -L "$target" ]; then existed=0; fi
    if "$@" >/dev/null 2>&1; then
        if [ -n "$target" ] && [ "$existed" = "0" ]; then
            # 命令成功，但目标在动手前就已不在 = 上一次已经删掉了。说清楚
            printf '    %s·%s 已不在（上次已删除）%s\n' "$C_0" "$C_0" "$desc"
        else
            ok "$desc"
        fi
    else
        printf '    %s✗%s %s —— 删除失败\n' "$C_R" "$C_0" "$desc"
        printf '      可手动执行：sudo %s\n' "$*"
    fi
}

# 需要 root：pfctl/route/删系统文件都要
if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行：sudo bash uninstall.sh"
    exit 1
fi

echo
say "SmartRoute 卸载（dry-run=${DRY} 保留日志=${KEEP_LOGS} 保留App=${KEEP_APP}）"
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

# ---------- 0.5 还原网络服务顺序（必须在删状态目录之前） ----------
# smartroute 每次切换都会用 networksetup -ordernetworkservices 把当前首选服务
# 挪到第一位，这是**持久化**修改：重启、重连网络都还在，卸载软件本身不会还原。
# 用户会在系统设置>网络里发现顺序被动过却不知道是谁干的，而脚本最后还告诉他
# "网络设置未改动"——对不上就彻底没信任了。所以按 smartroute 首次切换前存下的
# 原始顺序还原。存的是文件（一行一个服务名），因为服务名可能含空格。
SVC_ORDER_BAK="/var/db/smartroute/svc_order_orig"
if [ "$DRY" = "1" ]; then
    printf '    %s·%s 将按 %s 还原网络服务顺序（若存在）\n' "$C_0" "$C_0" "$SVC_ORDER_BAK"
elif [ -s "$SVC_ORDER_BAK" ]; then
    _order=()
    while IFS= read -r _s; do
        [ -n "$_s" ] && _order+=("$_s")
    done < "$SVC_ORDER_BAK"
    if [ "${#_order[@]}" -gt 0 ]; then
        # 备份里可能有已经不存在的服务，networksetup 会整体失败；
        # 失败不致命——顺序留着只影响"默认走哪个"，不影响能不能上网。
        if networksetup -ordernetworkservices "${_order[@]}" >/dev/null 2>&1; then
            ok "已还原网络服务顺序（${#_order[@]} 个服务）"
        else
            warn "还原服务顺序失败（备份里的服务可能已不存在）"
            printf '      可手动恢复：系统设置 > 网络 > ⋯ > 设置服务顺序\n'
        fi
    fi
else
    skip "没有服务顺序备份（smartroute 没改过，或已被清掉）"
fi

# ---------- 0.6 还原被钉住的默认路由 ----------
# do_switch 的兜底路径会 `route delete default` + `route add default -interface`，
# 这样加出来的默认路由**没有任何清理机制**（守护进程的 EXIT trap 只清探测路由）。
# 卸完它还留着，默认路由就停在 smartroute 最后切过去的那个接口上——
# 用户不知道原因，只会觉得"卸载把网络搞坏了"。
#
# 处理原则：**绝不能让用户断网**。所以先记下当前默认路由的完整参数，
# 删掉它让 configd 按（已还原的）服务顺序重新裁决；等两秒，
# 如果 configd 没把它加回来，就原样加回去。
if [ "$DRY" = "1" ]; then
    printf '    %s·%s 若默认路由是被直接钉上去的，会删掉让系统重新裁决\n' "$C_0" "$C_0"
elif [ -n "$(route -n get default 2>/dev/null | awk '/^ *interface:/{print $2; exit}')" ]; then
    _d_gw="$(route -n get default 2>/dev/null | awk '/^ *gateway:/{print $2; exit}')"
    _d_if="$(route -n get default 2>/dev/null | awk '/^ *interface:/{print $2; exit}')"
    if route delete default >/dev/null 2>&1; then
        ok "已删掉默认路由（让系统按服务顺序重新裁决）"
        # 给 configd 一点时间。它通常立刻就会按首选服务加回来。
        _back=0
        for _i in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.2
            if [ -n "$(route -n get default 2>/dev/null | awk '/^ *interface:/{print $2; exit}')" ]; then
                _back=1; break
            fi
        done
        if [ "$_back" = "1" ]; then
            ok "系统已自动重建默认路由（interface=$(route -n get default 2>/dev/null | awk '/^ *interface:/{print $2; exit}')）"
        elif [ -n "$_d_gw" ]; then
            # configd 没动静：原样加回去，绝不把用户留在没有默认路由的状态
            #
            # ⚠️ 这里原来调 `route_add_default "$_d_if" "$_d_gw"`——而那个
            # 函数定义在 smartroute.sh 里，uninstall.sh 既没定义也没 source，
            # 全文只有这一处引用。实测（mock 一个 configd 2 秒内不重建的
            # route）：命令找不到，直接落到 else 分支告警，而默认路由
            # 始终不存在——**用户被留在断网状态**，注释承诺的兜底
            # 100% 走不到。卸载脚本卸载到一半把网弄丢，是最坏的一种失败。
            #
            # 改成内联实现，不依赖另一个脚本的作用域。
            # 两种写法都试：带 -interface 的写法在网关不在该接口网段时
            # 会失败，退回让内核自己选出口。
            if route add default -interface "$_d_if" "$_d_gw" 2>/dev/null \
               || route add default "$_d_gw" -interface "$_d_if" 2>/dev/null; then
                warn "系统未自动重建，已按原参数加回（interface=${_d_if} gateway=${_d_gw}）"
            else
                warn "默认路由未能自动重建——请手动开关一次 Wi-Fi 或重启 Mac"
            fi
        else
            warn "默认路由未能自动重建——请手动开关一次 Wi-Fi 或重启 Mac"
        fi
    else
        skip "默认路由删不掉（可能本就不是我们加的）"
    fi
else
    skip "没有默认路由"
fi

# ---------- 1. pf 分流规则 ----------
say "清理 pf 分流规则"
ANCHOR="com.apple/smartroute"
if [ "$DRY" = "0" ]; then
    if pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -q .; then
        pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 && ok "已刷掉锚点 $ANCHOR 内的规则" || warn "刷规则失败"
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
run "锚点文件 /etc/pf.anchors/com.user.smartroute" /etc/pf.anchors/com.user.smartroute rm -f /etc/pf.anchors/com.user.smartroute

# ---------- 2. 路由清理 ----------
say "清理路由"
if [ "$DRY" = "0" ]; then
    # 探测目标从配置里读，不用硬编码列表。硬编码永远追不上用户自定义的
    # PROBE_TARGETS（比如默认值里的 119.29.29.29 就不在旧列表里），
    # 结果是卸完路由表里还留着来历不明的主机路由。
    n=0
    _probes="1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 208.67.222.222 223.5.5.5 114.114.114.114 119.29.29.29"
    for _cf in /etc/smartroute.conf /Users/Shared/smartroute.conf; do
        [ -f "$_cf" ] || continue
        _v="$(grep -m1 '^PROBE_TARGETS=' "$_cf" | cut -d= -f2-)"
        [ -n "$_v" ] && _probes="$_v"
    done
    for t in $_probes; do
        route delete -host "$t" >/dev/null 2>&1 && n=$((n+1))
    done
    [ "$n" -gt 0 ] && ok "删了 $n 条探测主机路由" || skip "没有残留的探测路由"
    # 分流规则落地成的是 -net 静态路由（守护进程照 smartroute.rules 加的）。
    # 以前只删 -host 那 8 个探测目标，这些 -net 路由一个都没清——
    # 卸完软件路由表里还留着"某网段走某接口"，用户完全不知道是哪来的。
    # 必须在删规则文件**之前**读，否则就不知道要删什么了。
    n2=0
    if [ -f /Users/Shared/smartroute.rules ]; then
        while read -r cidr dev _rest; do
            case "$cidr" in ""|\#*) continue ;; esac
            [ -n "$dev" ] || continue
            if route delete -net "$cidr" -interface "$dev" >/dev/null 2>&1 || \
               route delete -net "$cidr" >/dev/null 2>&1; then
                n2=$((n2+1))
                printf '    %s·%s 删除网段路由 %s via %s\n' "$C_0" "$C_0" "$cidr" "$dev"
            fi
        done < /Users/Shared/smartroute.rules
    fi
    [ "$n2" -gt 0 ] && ok "删了 $n2 条分流网段路由" || skip "没有分流网段路由"
else
    printf '    %s·%s 将删除探测 -host 路由（按你配置的 PROBE_TARGETS）和分流 -net 路由\n' "$C_0" "$C_0"
    # dry-run 的意义就是"让我看清会动什么"。原来只给一句通用描述，
    # 用户最关心的"到底删我哪几条路由"答不出来。
    if [ -f /Users/Shared/smartroute.rules ]; then
        while read -r _c _d _rest; do
            case "$_c" in ""|\#*) continue ;; esac
            [ -n "$_d" ] && printf '    %s·%s 网段路由 %s via %s\n' "$C_0" "$C_0" "$_c" "$_d"
        done < /Users/Shared/smartroute.rules
    fi
    # 两条最容易踩的预期差，dry-run 时就说清楚
    printf '    %s·%s 服务顺序会按备份还原（若从未改过则无备份可还原）\n' "$C_0" "$C_0"
    if [ "$KEEP_LOGS" = "1" ]; then
        printf '    %s·%s 日志将保留\n' "$C_0" "$C_0"
    else
        printf '    %s·%s 日志默认删除——想留着排查加 --keep-logs\n' "$C_0" "$C_0"
    fi
    printf '    %s·%s 导入前的配置备份 .conf.bak 会保留，不删\n' "$C_0" "$C_0"
fi

# ---------- 3. 程序与配置 ----------
say "删除程序与配置"
run "命令行工具 /usr/local/bin/smartroute"       /usr/local/bin/smartroute rm -f /usr/local/bin/smartroute
run "免权限扫描 helper /usr/local/bin/smartroute-wifiscan" /usr/local/bin/smartroute-wifiscan rm -f /usr/local/bin/smartroute-wifiscan
run "守护进程 plist"                             /Library/LaunchDaemons/com.user.smartroute.plist rm -f /Library/LaunchDaemons/com.user.smartroute.plist
run "系统配置 /etc/smartroute.conf"              /etc/smartroute.conf rm -f /etc/smartroute.conf
run "用户配置 /Users/Shared/smartroute.conf"     /Users/Shared/smartroute.conf rm -f /Users/Shared/smartroute.conf
run "用户配置临时残留 .conf.tmp*"                /Users/Shared/smartroute.conf.tmp* bash -c 'rm -f /Users/Shared/smartroute.conf.tmp*'
# .conf.bak 是 App 导入配置前自动备份的用户原始配置，导入成功的提示里
# 明写"原配置备份为 smartroute.conf.bak"、注释原话"留个后悔药"。
# 卸载时静默删掉它，等于把用户唯一的退路悄悄拿走——而这是我们自己承诺过的。
# 所以保留，并在输出里说清路径，让用户自己决定。
if [ -f /Users/Shared/smartroute.conf.bak ]; then
    warn "保留导入前的配置备份 /Users/Shared/smartroute.conf.bak（你自己决定要不要删）"
else
    skip "没有导入前的配置备份"
fi
run "分流规则 /Users/Shared/smartroute.rules"    /Users/Shared/smartroute.rules rm -f /Users/Shared/smartroute.rules
run "状态目录 /var/db/smartroute"                /var/db/smartroute rm -rf /var/db/smartroute
run "锁目录 /var/run/smartroute.lock"            /var/run/smartroute.lock rm -rf /var/run/smartroute.lock
run "/tmp 探测残留"                              /tmp/.smartroute.probe.* bash -c 'rm -f /tmp/.smartroute.probe.*'
# App 开机自启的 plist。注意：从 App 里点卸载时这个脚本是以 root 跑的，
# $HOME 是 /var/root——只删 "$HOME/..." 会删错地方，真正的用户 plist 留在
# /Users/<user>/Library/LaunchAgents/ 里，校验却查同一个错路径，照样打印"✅ 零残留"。
# 所以要：bootout 掉已加载的 job（只 rm plist 不 bootout，job 活到重启），
# 并遍历所有真实用户主目录删 plist。
if [ "$DRY" = "0" ]; then
    for _h in "$HOME" /Users/*; do
        [ -d "$_h/Library/LaunchAgents" ] || continue
        _p="$_h/Library/LaunchAgents/com.user.smartroute.app.plist"
        [ -f "$_p" ] || continue
        launchctl bootout "gui/$(stat -f '%u' "$_h")/com.user.smartroute.app" >/dev/null 2>&1 || true
        rm -f "$_p" && printf '    %s·%s 删除 %s\n' "$C_0" "$C_0" "$_p"
    done
fi
run "登录自启 plist（App 开机自启）"            - bash -c 'for h in "$HOME" /Users/*; do [ -d "$h/Library/LaunchAgents" ] && rm -f "$h/Library/LaunchAgents/com.user.smartroute.app.plist"; done; true' 
if [ "$KEEP_LOGS" = "1" ]; then
    warn "按要求保留日志：/var/log/smartroute.{log,out,err}"
else
    run "日志 /var/log/smartroute.log"            /var/log/smartroute.log rm -f /var/log/smartroute.log
    # 日志超 1MB 会轮转成 .log.1（smartroute.sh 里做的），以前不删这个，
    # 卸完 /var/log 里还躺着上一代日志。
    run "日志轮转 /var/log/smartroute.log.*"      /var/log/smartroute.log.* bash -c 'rm -f /var/log/smartroute.log.*' 
    run "守护进程 stdout /var/log/smartroute.out" /var/log/smartroute.out rm -f /var/log/smartroute.out
    run "守护进程 stderr /var/log/smartroute.err" /var/log/smartroute.err rm -f /var/log/smartroute.err
    # log() 也会把 .out/.err 轮转成 .out.1/.err.1，旧版只删本体，
    # 卸完 /var/log 里还躺着上一代——"零残留"就漏了。
    run "守护进程 stdout 轮转 /var/log/smartroute.out.*" /var/log/smartroute.out.* bash -c 'rm -f /var/log/smartroute.out.*'
    run "守护进程 stderr 轮转 /var/log/smartroute.err.*" /var/log/smartroute.err.* bash -c 'rm -f /var/log/smartroute.err.*'
    # 用户级配置的临时残留（state_set 的 $STATE_FILE.$$ 同类）
    run "状态临时残留 /var/db/smartroute/*.tmp"  /var/db/smartroute/*.tmp bash -c 'rm -f /var/db/smartroute/*.tmp' 
fi

# ---------- 4. App 本体 ----------
say "App 本体"
APP="/Applications/SmartRoute.app"
if [ "$KEEP_APP" = "1" ]; then
    warn "保留 ${APP}（可随时自己拖进废纸篓）"
elif [ -d "$APP" ]; then
    if [ "$DRY" = "1" ]; then
        printf '    %s·%s 将删除 %s\n' "$C_0" "$C_0" "$APP"
    elif [ "$YES" = "1" ]; then
        # --yes 是一把梭，用户不会逐行看输出。删完给一句回执，
        # 把"我刚删了什么、什么被留下来了"说清——否则他以为日志也留着了。
        rm -rf "$APP" && ok "已删除 $APP" || warn "删除 App 失败"
        if [ "$KEEP_LOGS" = "1" ]; then
            printf '    %s·%s 日志已按 --keep-logs 保留在 /var/log/smartroute.*\n' "$C_0" "$C_0"
        else
            printf '    %s·%s 日志已删除（下次想保留加 --keep-logs）\n' "$C_0" "$C_0"
        fi
        [ -f /Users/Shared/smartroute.conf.bak ] && \
            printf '    %s·%s 配置备份仍在：/Users/Shared/smartroute.conf.bak\n' "$C_0" "$C_0"
    else
        printf '    删除 %s ？[y/N] ' "$APP"
        read -r ans
        case "$ans" in
            y|Y|yes) rm -rf "$APP" && ok "已删除 $APP" || warn "删除 App 失败" ;;
            *) warn "保留 ${APP}（可随时自己拖进废纸篓）" ;;
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
    # 这份清单必须和上面的删除清单**逐项对应**。以前有四项删了却不验
    # （.conf.tmp*、.out.1/.err.1、App 放在 ~/Applications），
    # 结果是"✅ 零残留"有时是假的——用户唯一想从卸载得到的答案就是这个，
    # 骗他一次，之前所有诚实的交代都作废。
    # .conf.bak 是故意保留的（见上），所以不在这份清单里，下面单独说明。
    for f in /usr/local/bin/smartroute /usr/local/bin/smartroute-wifiscan \
             /Users/Shared/smartroute.rules.tmp /Users/Shared/smartroute.conf.tmp* \
             /Library/LaunchDaemons/com.user.smartroute.plist \
             /etc/smartroute.conf /Users/Shared/smartroute.conf \
             /Users/Shared/smartroute.rules \
             /etc/pf.anchors/com.user.smartroute /var/db/smartroute /var/run/smartroute.lock \
             "$HOME/Library/LaunchAgents/com.user.smartroute.app.plist" \
             /Users/*/Library/LaunchAgents/com.user.smartroute.app.plist \
             /Applications/SmartRoute.app "$HOME/Applications/SmartRoute.app"; do
        if [ -e "$f" ] || [ -L "$f" ]; then printf '    %s✗%s 仍在: %s\n' "$C_R" "$C_0" "$f"; left=$((left+1)); fi
    done
    if [ "$KEEP_LOGS" != "1" ]; then
        for f in /var/log/smartroute.log /var/log/smartroute.log.* \
                 /var/log/smartroute.out /var/log/smartroute.out.* \
                 /var/log/smartroute.err /var/log/smartroute.err.*; do
            [ -e "$f" ] && { printf '    %s✗%s 仍在: %s\n' "$C_R" "$C_0" "$f"; left=$((left+1)); }
        done
    fi
    # .conf.bak 是故意留的，说清楚，别让人以为校验漏了它
    if [ -f /Users/Shared/smartroute.conf.bak ]; then
        printf '    %s·%s 按设计保留: /Users/Shared/smartroute.conf.bak（导入前的配置备份）\n' "$C_0" "$C_0"
    fi
    if ls /tmp/.smartroute.probe.* >/dev/null 2>&1; then
        printf '    %s✗%s /tmp 仍有探测残留\n' "$C_R" "$C_0"; left=$((left+1))
    fi
    # App 的偏好和 Saved State。这些在用户自己的 Library 里，不属于"程序装到哪里"，
    # 但"零残留"这句话得兜得住——所以要么删，要么明说不删。
    for _h in /Users/*; do
        [ -d "$_h/Library" ] || continue
        _pb="$_h/Library/Preferences/com.user.smartroute.app.plist"
        _sb="$_h/Library/Saved Application State/com.user.smartroute.app.savedState"
        if [ -f "$_pb" ]; then
            printf '    %s·%s App 偏好仍在: %s（未删，属用户数据）\n' "$C_0" "$C_0" "$_pb"
        fi
        if [ -e "$_sb" ]; then
            printf '    %s·%s App 窗口状态仍在: %s（未删，属用户数据）\n' "$C_0" "$C_0" "$_sb"
        fi
    done
    if pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -q .; then
        printf '    %s✗%s pf 锚点里仍有规则\n' "$C_R" "$C_0"; left=$((left+1))
    fi
    if pgrep -f "smartroute watch" >/dev/null 2>&1; then
        printf '    %s✗%s watch 进程仍在运行\n' "$C_R" "$C_0"; left=$((left+1))
    fi

    # 用户卸完真正想知道的是"我的网络被改了吗"。以前这句是拍脑袋的
    # "网络设置未改动"——而服务顺序明明被改过（见 0.5 节）。
    # 现在如实报告默认路由和 pf 的真实状态，让他自己能核对。
    echo
    say "网络现状（供你核对）"
    _def="$(route -n get default 2>/dev/null | awk '/^ *gateway:/{print $2; exit}')"
    _ifc="$(route -n get default 2>/dev/null | awk '/^ *interface:/{print $2; exit}')"
    if [ -n "$_ifc" ]; then
        printf '    %s·%s 默认路由：interface=%s gateway=%s\n' "$C_0" "$C_0" "$_ifc" "${_def:-未知}"
    else
        printf '    %s·%s 默认路由：读不到（系统会自己重新裁决）\n' "$C_0" "$C_0"
    fi
    # pf 状态：我们开过的要关掉（见上面），用户自己开的别动。说清楚是哪种。
    if [ -f /var/db/smartroute/pf.state ] && grep -q "pf_enabled_by_us=1" /var/db/smartroute/pf.state 2>/dev/null; then
        printf '    %s·%s 系统 pf：本工具曾开启，已关闭\n' "$C_0" "$C_0"
    elif pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
        printf '    %s·%s 系统 pf：当前为开启（这是你自己的设置，未改动）\n' "$C_0" "$C_0"
    else
        printf '    %s·%s 系统 pf：当前为关闭（与安装前一致）\n' "$C_0" "$C_0"
    fi
    if [ -s "$SVC_ORDER_BAK" ]; then
        printf '    %s·%s 服务顺序：已按备份还原\n' "$C_0" "$C_0"
    else
        printf '    %s·%s 服务顺序：本工具没有改过（无备份可还原）\n' "$C_0" "$C_0"
    fi

    if [ "$left" -eq 0 ]; then
        # 措辞要兜得住。App 偏好和窗口状态在用户自己的 Library 里，属用户数据，
        # 上面只提示不删——所以不能说"所有东西都清干净了"。
        printf '    %s✅ 程序、配置、规则、路由、进程都已清干净%s\n' "$C_G" "$C_0"
        printf '    %s   （App 偏好与窗口状态属用户数据，未删；上面已列出路径）%s\n' "$C_0" "$C_0"
    else
        printf '    %s还有 %d 项残留（见上）%s\n' "$C_Y" "$left" "$C_0"
        printf '    %s  重跑一次：sudo bash %s --yes%s\n' "$C_0" "$C_0" "$0"
        printf '    %s  或照上面每条给出的手动命令逐条删%s\n' "$C_0" "$C_0"
    fi
    echo
    # 标题必须按 left 分叉。原来无条件说"卸载完成。接下来："，于是有残留时
    # 输出里同时存在"还有 N 项残留（见上）"和"卸载完成"两句话——自相矛盾，
    # 而 App 的 daemonResultSummary 只匹配"卸载完成"，会把残留报告成
    # 绿色的"都已清干净"。脚本侧先别伪装，App 侧才好如实翻译。
    if [ "$left" -eq 0 ]; then
        say "卸载完成。接下来："
    else
        say "卸载未完全：还有 ${left} 项残留（见上）。接下来："
    fi
    echo "    1. App 本体按你的选择保留着——拖进废纸篓即可（见上面提示）"
    echo "    2.  退出 App（菜单栏图标随之消失）"
    echo "    3.  如果上网感觉异常：开关一次 Wi-Fi，或重启 Mac，让系统重新裁决路由"
    echo "    4.  导入前的配置备份若还在，路径见上面；不需要就自己删掉"
    echo
    echo "    本工具没有动过：DNS、VPN、系统代理、hosts、系统 pf 开关"
else
    echo
    say "dry-run 结束，未做任何改动。去掉 --dry-run 正式执行。"
fi
echo

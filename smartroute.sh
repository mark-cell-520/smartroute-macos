#!/bin/bash
#
# smartroute.sh — macOS 有线/无线双网卡智能选路
#
# 解决的问题：
#   Mac 同时连接以太网（没有外网 / 网关不可达）和 Wi-Fi 时，macOS 按“服务顺序”
#   决定默认路由——第一个活跃的服务提供默认路由。以太网排在前面时，全部流量
#   走进那个没有外网的网关，即使 Wi-Fi 正常也无法上网。
#
#   本工具每隔一段时间探测各个接口的外网连通性，需要时自动：
#     1) 调整“服务顺序”（持久生效，macOS 网络重连后依然有效）
#     2) 必要时直接改路由表（立即生效的兜底手段）
#   实现效果：
#     - 以太网有外网   → 走以太网（其局域网网段路由保留）
#     - 以太网无外网   → 走 Wi-Fi，内网流量仍然走以太网
#
# 用法：
#   sudo smartroute watch        执行一次检测/切换（launchd 定时调用，也可手动）
#   sudo smartroute status       查看当前状态（只读）
#   sudo smartroute test [-v]    手动探测各接口连通性（-v 显示分层明细，不切换）
#   sudo smartroute doctor       一键体检：定位“为什么上不了网”
#   sudo smartroute set auto|ethernet|wifi   设置选路模式
#   sudo smartroute config       显示当前生效配置
#   smartroute log [行数]        查看日志
#
# 配置文件：
#   /etc/smartroute.conf            系统级（root 维护）
#   /Users/Shared/smartroute.conf   用户级（SmartRoute App 维护，优先级更高，无需 sudo）

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---------------- 默认配置（可被 /etc/smartroute.conf 覆盖） ----------------
MODE="auto"                 # auto | ethernet | wifi
OK_N=2                      # 连续探测成功 N 次 → 判定“可用”
FAIL_N=3                    # 连续探测失败 N 次 → 判定“不可用”
COOLDOWN=45                 # 两次切换之间的最小间隔（秒），防止抖动
PROBE_TARGETS="223.5.5.5 119.29.29.29 114.114.114.114 1.1.1.1 8.8.8.8"
PING_TIMEOUT=800            # ping 超时（毫秒）
NC_TIMEOUT=2                # TCP 探测超时（秒）
TLS_PROBE=1                 # ping/TCP 都失败时用 TLS 握手做最后确认（识别“假互联网”）
NOTIFY=0                    # 发生切换时弹系统通知（1 开启）
AUTO_WIFI_POWER=0           # 以太网无外网且 Wi-Fi 被关闭时，自动打开 Wi-Fi（1 开启）
BALANCE=0                   # 双网并发分流开关（1 开启，pf 轮询；需 sudo smartroute balance on）

# 可用 set 命令修改的配置项
VALID_KEYS="MODE OK_N FAIL_N COOLDOWN PROBE_TARGETS PING_TIMEOUT NC_TIMEOUT TLS_PROBE NOTIFY AUTO_WIFI_POWER BALANCE"

CONF="/etc/smartroute.conf"                     # 系统级配置（root 维护，install.sh 生成）
USER_CONF="/Users/Shared/smartroute.conf"       # 用户级配置（App/普通用户可写，优先级更高）
RULES_FILE="/Users/Shared/smartroute.rules"     # 分流规则（每行: CIDR 接口，普通用户可写，守护进程应用）
STATE_FILE="/var/db/smartroute/state"
LOG_FILE="/var/log/smartroute.log"
LOCK_DIR="/var/run/smartroute.lock"
PROBE_DETAIL_FILE="/tmp/.smartroute.probe.$$"   # 探测明细（跨命令替换子 shell 传递）
PF_ANCHOR="com.user.smartroute"                 # pf 锚点名（双网并发分流用）
PF_ANCHOR_FILE="/etc/pf.anchors/$PF_ANCHOR"     # pf 规则文件
PF_STATE_FILE="/var/db/smartroute/pf.state"     # 记录我们是否开启了系统 pf（用于还原）

[ -r "$CONF" ] && . "$CONF"
[ -r "$USER_CONF" ] && . "$USER_CONF"           # 用户级覆盖系统级

# ---------------- 基础函数 ----------------
ts()  { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    local msg="$*"
    printf '%s %s\n' "$(ts)" "$msg" >> "$LOG_FILE" 2>/dev/null
    if [ -f "$LOG_FILE" ]; then
        local sz
        sz=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        [ "$sz" -gt 1048576 ] && mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
    fi
    return 0
}

die() { echo "错误: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: smartroute <命令>

  watch        执行一次检测/切换（launchd 定时调用；也可 sudo smartroute watch 手动执行）
  status       查看当前网络状态与选路决策（只读）
  test [-v]    手动探测各接口外网连通性（-v 显示分层明细，不切换）
  doctor       一键体检：定位“为什么上不了网”（网关/DNS/HTTPS/门户/网段冲突）
  set          设置选路模式: auto | ethernet | wifi；也可 set KEY=VALUE（如 NOTIFY=1，普通用户可写用户级配置）
  config       显示当前生效配置（含两个配置文件内容）
  log          查看最近日志（默认 50 行）

双网并发 / 分流:
  balance on    开启双网并发分流（需 sudo；两个接口都要有外网，自动验证，失败自动还原）
  balance off   关闭并发分流并恢复原状（需 sudo）
  balance status 查看并发分流状态
  rule add <CIDR> <接口>   添加静态分流规则，如 rule add 10.0.0.0/8 en0（普通用户可写，守护进程应用）
  rule del <CIDR>          删除规则
  rule list                查看规则及生效情况

监控:
  stats        各活跃接口的累计收发字节（供 App 计算实时速率）
  quality      逐接口测延迟/丢包（root 下强制走指定接口）

示例:
  sudo smartroute watch
  sudo smartroute status
  sudo smartroute test -v
  sudo smartroute doctor
  sudo smartroute set wifi
  sudo smartroute balance on
  smartroute rule add 10.0.0.0/8 en0
EOF
    exit 1
}

# ---------------- 网络信息采集 ----------------

# 服务顺序列表：输出 "服务名"
ordered_service_names() {
    networksetup -listnetworkserviceorder 2>/dev/null \
        | sed -n 's/^([*0-9]*) //p' | sed 's/[[:space:]]*$//'
}

# 服务 -> 设备 映射：输出 "服务名<TAB>设备"
# 注意：服务名行形如 "(*) 服务名" 或 "(1) 服务名"，
# 而 "(Hardware Port: X, Device: enY)" 行也以 "(" 开头，必须排除。
service_devices() {
    networksetup -listnetworkserviceorder 2>/dev/null | awk '
        /^\([*0-9]+\)[[:space:]]/ {
            line = $0
            sub(/^\([^)]*\)[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)
            name = line
        }
        /Device: / {
            d = $0
            sub(/^.*Device:[[:space:]]*/, "", d)
            sub(/\).*$/, "", d)
            sub(/[[:space:]]+$/, "", d)
            if (name != "" && d != "") print name "\t" d
        }
    '
}

# 硬件端口列表：输出 "端口名<TAB>设备"
hardware_ports() {
    networksetup -listallhardwareports 2>/dev/null | awk '
        /^Hardware Port: / {
            p = $0
            sub(/^Hardware Port:[[:space:]]*/, "", p)
            sub(/[[:space:]]+$/, "", p)
        }
        /^Device: / {
            d = $0
            sub(/^Device:[[:space:]]*/, "", d)
            sub(/[[:space:]]+$/, "", d)
            if (p != "" && d != "") print p "\t" d
        }
    '
}

ETH_PORT_RE='ethernet|以太|usb.*lan|lan.*usb'
WIFI_PORT_RE='wi-?fi|airport|无线'

is_eth_port()  { printf '%s' "$1" | grep -qiE "$ETH_PORT_RE"; }
is_wifi_port() { printf '%s' "$1" | grep -qiE "$WIFI_PORT_RE"; }

dev_ipv4()  { ifconfig "$1" 2>/dev/null | awk '/^[ \t]*inet /{print $2; exit}'; }
dev_active() { [ -n "$(dev_ipv4 "$1")" ]; }

svc_of_dev() {   # $1=设备 -> 服务名（没有则为空）
    [ -n "$1" ] || return 0
    service_devices | awk -F'\t' -v d="$1" '$2==d{print $1; exit}'
}

svc_router() {   # $1=服务名 -> 网关
    [ -n "$1" ] || return 0
    networksetup -getinfo "$1" 2>/dev/null | awk -F': *' '/^Router:/{print $2; exit}'
}

default_dev() {
    route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'
}

default_gw() {
    route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}'
}

# 服务是否启用（服务顺序里带 (*) 表示禁用）
svc_enabled() {   # $1=服务名 -> 0 启用 / 1 禁用或不存在
    [ -n "$1" ] || return 1
    networksetup -listnetworkserviceorder 2>/dev/null | sed -n 's/^(\*) //p' | grep -qxF "$1" && return 1
    return 0
}

wifi_power() {   # $1=设备 -> on/off/unknown
    local out
    out="$(networksetup -getairportpower "$1" 2>/dev/null)"
    case "$out" in
        *On*)  echo on ;;
        *Off*) echo off ;;
        *)     echo unknown ;;
    esac
}

set_wifi_power() {  # $1=设备 $2=on/off
    networksetup -setairportpower "$1" "$2" >/dev/null 2>&1
}

notify() {   # $1=标题 $2=内容
    [ "$NOTIFY" = "1" ] || return 0
    command -v osascript >/dev/null 2>&1 || return 0
    osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1
    return 0
}

human_ts() {   # epoch -> "3 分钟前"
    local e="$1" now d
    if ! [[ "$e" =~ ^[0-9]+$ ]] || [ "$e" -le 0 ]; then echo "从未"; return; fi
    now=$(date +%s); d=$((now - e))
    if   [ "$d" -lt 60 ];    then echo "${d} 秒前"
    elif [ "$d" -lt 3600 ];  then echo "$((d/60)) 分钟前"
    elif [ "$d" -lt 86400 ]; then echo "$((d/3600)) 小时前"
    else echo "$((d/86400)) 天前"; fi
}

bump_switch_count() {
    local c
    c="$(state_get switch_count)"
    [[ "$c" =~ ^[0-9]+$ ]] || c=0
    state_set switch_count "$((c+1))"
}

# 终端着色（仅 stdout 是 tty 时启用）
if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_RST=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_ERR=""; C_RST=""
fi

# 找到当前活跃的以太网设备与 Wi-Fi 设备（含服务名）
find_active() {
    ACTIVE_ETH_DEV="";  ACTIVE_ETH_SVC=""
    ACTIVE_WIFI_DEV=""; ACTIVE_WIFI_SVC=""
    local line port dev cur
    cur="$(default_dev)"
    while IFS="	" read -r port dev; do
        [ -n "$dev" ] || continue
        dev_active "$dev" || continue
        if is_wifi_port "$port"; then
            [ -z "$ACTIVE_WIFI_DEV" ] && ACTIVE_WIFI_DEV="$dev"
            # 当前默认路由就在该 Wi-Fi 上，优先采用
            [ "$cur" = "$dev" ] && ACTIVE_WIFI_DEV="$dev"
        elif is_eth_port "$port"; then
            [ -z "$ACTIVE_ETH_DEV" ] && ACTIVE_ETH_DEV="$dev"
            [ "$cur" = "$dev" ] && ACTIVE_ETH_DEV="$dev"
        fi
    done < <(hardware_ports)

    [ -n "$ACTIVE_ETH_DEV" ]  && ACTIVE_ETH_SVC="$(svc_of_dev "$ACTIVE_ETH_DEV")"
    [ -n "$ACTIVE_WIFI_DEV" ] && ACTIVE_WIFI_SVC="$(svc_of_dev "$ACTIVE_WIFI_DEV")"
}

# ---------------- 路由操作（兼容不同参数顺序） ----------------
route_add_host() {   # $1=目标IP $2=设备 $3=网关
    route add -host "$1" -interface "$2" "$3" 2>/dev/null && return 0
    route add -host "$1" "$3" -interface "$2" 2>/dev/null && return 0
    route add -host "$1" "$3" 2>/dev/null && return 0
    return 1
}

route_add_default() {  # $1=设备 $2=网关
    route add default -interface "$1" "$2" 2>/dev/null && return 0
    route add default "$2" -interface "$1" 2>/dev/null && return 0
    route add default "$2" 2>/dev/null && return 0
    return 1
}

cleanup_probe_routes() {
    local t
    for t in $PROBE_TARGETS 1.1.1.1 8.8.8.8; do
        route delete -host "$t" >/dev/null 2>&1
    done
    return 0
}

# ---------------- 连通性探测 ----------------
# 输出: ok / fail / na（接口未激活）；明细写入 PROBE_DETAIL_FILE 文件
# （probe_dev 常在 $(...) 子 shell 中被调用，全局变量传不出来，故用文件传递）
# 原理：root 下给探测目标加临时主机路由强制走指定接口，从而可以探测
# “当前不是默认路由”的接口；探测完立即删除，不影响正常流量。
# 三层探测：
#   1) ping        —— 快，但可能被防火墙禁 ICMP
#   2) TCP 53/443  —— 穿透大部分禁 ping 的网络
#   3) TLS 握手    —— 识别“TCP 通但没有真正互联网”的场景（门户劫持/假链）
set_probe_detail() {   # $1=明细内容（同时写全局变量和文件）
    PROBE_DETAIL="$1"
    printf '%s' "$1" > "$PROBE_DETAIL_FILE" 2>/dev/null
}

probe_dev() {   # $1=设备 $2=网关
    local dev="$1" gw="$2" t ok=1 added=0
    local ping_ok=0 tcp_ok=0 tls_ok=0 targets
    set_probe_detail ""
    [ -n "$dev" ] || { set_probe_detail "接口未指定"; echo na; return; }
    dev_active "$dev" || { set_probe_detail "接口未激活/无 IP"; echo na; return; }

    targets="$PROBE_TARGETS"
    [ "$TLS_PROBE" = "1" ] && targets="$targets 1.1.1.1 8.8.8.8"

    if [ "$(id -u)" -eq 0 ] && [ -n "$gw" ]; then
        for t in $targets; do
            route_add_host "$t" "$dev" "$gw" && added=$((added+1))
        done
        if [ "$added" -eq 0 ]; then
            # 网关不在线/不可达，该接口不可能有外网
            set_probe_detail "网关 $gw 不可达（无法添加主机路由）"
            echo fail; return
        fi
    elif [ -z "$gw" ]; then
        # 有 IP 但没有网关（例如 169.254 自分配地址），不可能有外网
        set_probe_detail "有 IP 但无网关（可能是 169.254 自分配地址）"
        echo fail; return
    else
        set_probe_detail "非 root：按当前默认路由探测"
    fi

    # 第一轮 ping（快）
    for t in $targets; do
        ping -c 1 -W "$PING_TIMEOUT" "$t" >/dev/null 2>&1 && { ping_ok=1; ok=0; break; }
    done
    # 第二轮 TCP 兜底（防止 ICMP 被禁）
    if [ "$ok" -ne 0 ]; then
        for t in $targets; do
            if nc -z -w "$NC_TIMEOUT" "$t" 53 >/dev/null 2>&1 || nc -z -w "$NC_TIMEOUT" "$t" 443 >/dev/null 2>&1; then
                tcp_ok=1; ok=0; break
            fi
        done
    fi
    # 第三轮 TLS 握手（确认是“真互联网”，能过证书校验）
    if [ "$ok" -ne 0 ] && [ "$TLS_PROBE" = "1" ] && command -v curl >/dev/null 2>&1; then
        for t in 1.1.1.1 8.8.8.8; do
            case " $targets " in *" $t "*) ;; *) continue ;; esac
            if curl -s -m 4 -o /dev/null "https://$t/"; then tls_ok=1; ok=0; break; fi
        done
    fi

    [ "$added" -gt 0 ] && cleanup_probe_routes
    set_probe_detail "${PROBE_DETAIL}${PROBE_DETAIL:+；}ping=$ping_ok tcp=$tcp_ok tls=$tls_ok"
    [ "$ok" -eq 0 ] && echo ok || echo fail
}

# ---------------- 状态持久化（跨 launchd 调用） ----------------
state_get() {
    awk -F= -v k="$1" '$1==k{print $2; exit}' "$STATE_FILE" 2>/dev/null
}

state_set() {
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
    local tmp="$STATE_FILE.$$"
    if [ -f "$STATE_FILE" ]; then
        grep -v "^$1=" "$STATE_FILE" > "$tmp" 2>/dev/null
    fi
    printf '%s=%s\n' "$1" "$2" >> "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    return 0
}

update_streak() {   # $1=eth|wifi  $2=ok|fail|na -> 输出新连续值
    local n="$1" r="$2" s
    s="$(state_get "streak_$n")"
    [[ "$s" =~ ^-?[0-9]+$ ]] || s=0
    case "$r" in
        ok)   if [ "$s" -gt 0 ]; then s=$((s+1)); else s=1; fi ;;
        fail) if [ "$s" -lt 0 ]; then s=$((s-1)); else s=-1; fi ;;
        na)   s=0 ;;
    esac
    state_set "streak_$n" "$s"
    echo "$s"
}

# ---------------- 切换动作 ----------------

# 把某个服务挪到服务顺序第一位（其余保持相对顺序）
reorder_first() {   # $1=服务名
    local primary="$1" svc
    local rest=()
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        [ "$svc" = "$primary" ] && continue
        rest+=("$svc")
    done < <(ordered_service_names)

    if [ "${#rest[@]}" -eq 0 ]; then
        networksetup -ordernetworkservices "$primary" >>"$LOG_FILE" 2>&1
    else
        networksetup -ordernetworkservices "$primary" "${rest[@]}" >>"$LOG_FILE" 2>&1
    fi
}

do_switch() {   # $1=目标设备 $2=原默认设备 $3=eth探测 $4=wifi探测 $5=eth_streak $6=wifi_streak
    local want="$1" cur="$2"
    local svc gw now
    svc="$(svc_of_dev "$want")"
    log "切换默认路由: ${cur:-无} -> $want (服务:${svc:-无}) [eth=$3/$5 wifi=$4/$6 mode=$MODE]"

    # 1) 首选：调整服务顺序（持久，网络重连后依然有效）
    if [ -n "$svc" ] && reorder_first "$svc"; then
        sleep 2
        now="$(default_dev)"
        if [ "$now" = "$want" ]; then
            log "完成：服务顺序已调整，默认路由 -> $now"
            state_set last_switch "$(date +%s)"
            bump_switch_count
            notify "smartroute 选路切换" "默认路由: ${cur:-无} → $want"
            return 0
        fi
        log "服务顺序已调整但默认路由仍为 ${now:-无}，尝试直接修改路由表"
    else
        log "无法通过服务顺序切换（服务名:${svc:-无}），尝试直接修改路由表"
    fi

    # 2) 兜底：直接改路由表，立即生效（configd 之后若重建默认路由，下次 watch 会再修正）
    gw="$(svc_router "$svc")"
    if [ -n "$gw" ]; then
        route delete default >/dev/null 2>&1
        if route_add_default "$want" "$gw"; then
            log "完成：路由表已改为 default via $gw ($want)"
            state_set last_switch "$(date +%s)"
            bump_switch_count
            notify "smartroute 选路切换" "默认路由: ${cur:-无} → $want"
        else
            log "失败：无法添加 default via $gw ($want)"
        fi
    else
        log "失败：目标接口没有网关信息"
    fi
}

# ---------------- 命令实现 ----------------
cmd_watch() {
    find_active
    local eth_res="na" wifi_res="na"
    [ -n "$ACTIVE_ETH_DEV" ]  && eth_res="$(probe_dev "$ACTIVE_ETH_DEV" "$(svc_router "$ACTIVE_ETH_SVC")")"
    [ -n "$ACTIVE_WIFI_DEV" ] && wifi_res="$(probe_dev "$ACTIVE_WIFI_DEV" "$(svc_router "$ACTIVE_WIFI_SVC")")"

    local se sw eth_ok wifi_ok cur want
    se="$(update_streak eth "$eth_res")"
    sw="$(update_streak wifi "$wifi_res")"
    cur="$(default_dev)"

    # 【保护】默认路由若由 VPN/拨号等第三方接口持有（utun/ppp/ipsec），不干预——
    # 那种情况下流量本来就走在隧道里，改服务顺序/路由表没有意义甚至有害。
    if [ -n "$cur" ] && [ "$cur" != "$ACTIVE_ETH_DEV" ] && [ "$cur" != "$ACTIVE_WIFI_DEV" ]; then
        echo "$(ts) default=$cur 由 VPN/其他接口持有，不干预"
        return 0
    fi

    # 可用性判定（带滞回，防止临界状态抖动）
    if   [ "$se" -ge "$OK_N" ];    then eth_ok=1
    elif [ "$se" -le "-$FAIL_N" ]; then eth_ok=0
    elif [ "$cur" = "$ACTIVE_ETH_DEV" ]; then eth_ok=1
    else eth_ok=0; fi

    if   [ "$sw" -ge "$OK_N" ];    then wifi_ok=1
    elif [ "$sw" -le "-$FAIL_N" ]; then wifi_ok=0
    elif [ "$cur" = "$ACTIVE_WIFI_DEV" ]; then wifi_ok=1
    else wifi_ok=0; fi

    state_set eth_ok "$eth_ok"
    state_set wifi_ok "$wifi_ok"

    # 【并发分流安全阀】任一口没有外网时自动关闭双网并发，避免把流量送进死口
    if [ "$BALANCE" = "1" ] && [ "$(id -u)" -eq 0 ]; then
        if [ "$eth_ok" -ne 1 ] || [ "$wifi_ok" -ne 1 ]; then
            log "并发分流安全阀: 以太网 ok=$eth_ok Wi-Fi ok=$wifi_ok，自动关闭双网并发"
            balance_off quiet
            notify "smartroute" "双网并发已自动关闭（接口状态变化）"
        elif ! pfctl -a "$PF_ANCHOR" -s rules 2>/dev/null | grep -q .; then
            # 规则丢失（系统重启后 pf 会恢复默认状态），尝试重新加载
            if [ -f "$PF_ANCHOR_FILE" ]; then
                log "并发分流: pf 规则丢失，重新加载"
                pfctl -e 2>/dev/null
                pfctl -a "$PF_ANCHOR" -f "$PF_ANCHOR_FILE" 2>/dev/null
            else
                log "并发分流: 规则文件不存在，关闭并发开关"
                balance_off quiet
            fi
        fi
    fi

    # 【分流规则】把用户级规则文件落地为静态路由（root 才做）
    if [ "$(id -u)" -eq 0 ]; then
        apply_rules
    fi

    # 【可选】以太网没有外网、Wi-Fi 却被关闭时，自动打开 Wi-Fi（需 AUTO_WIFI_POWER=1）
    if [ "$AUTO_WIFI_POWER" = "1" ] && [ -n "$ACTIVE_WIFI_DEV" ] \
       && [ "$wifi_res" = "na" ] && [ "$eth_ok" -ne 1 ] \
       && [ "$(wifi_power "$ACTIVE_WIFI_DEV")" = "off" ]; then
        log "以太网无外网且 Wi-Fi 已关闭，自动打开 Wi-Fi ($ACTIVE_WIFI_DEV)"
        set_wifi_power "$ACTIVE_WIFI_DEV" on
        notify "smartroute" "已自动打开 Wi-Fi"
    fi

    # 期望的首选设备
    want=""
    case "$MODE" in
        ethernet) [ "$eth_ok" -eq 1 ] && [ -n "$ACTIVE_ETH_DEV" ] && want="$ACTIVE_ETH_DEV" ;;
        wifi)     [ "$wifi_ok" -eq 1 ] && [ -n "$ACTIVE_WIFI_DEV" ] && want="$ACTIVE_WIFI_DEV" ;;
        *)        if [ "$eth_ok" -eq 1 ] && [ -n "$ACTIVE_ETH_DEV" ]; then
                      want="$ACTIVE_ETH_DEV"
                  elif [ "$wifi_ok" -eq 1 ] && [ -n "$ACTIVE_WIFI_DEV" ]; then
                      want="$ACTIVE_WIFI_DEV"
                  fi ;;
    esac

    echo "$(ts) eth=${ACTIVE_ETH_DEV:-无}($eth_res) wifi=${ACTIVE_WIFI_DEV:-无}($wifi_res) default=${cur:-无} want=${want:-保持} mode=$MODE"

    if [ -n "$want" ] && [ "$want" != "$cur" ]; then
        # 冷却期，防止在两个接口间反复横跳
        local now last
        now=$(date +%s)
        last="$(state_get last_switch)"
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        if [ $((now - last)) -lt "$COOLDOWN" ]; then
            log "冷却期中（距上次切换 $((now - last))s < ${COOLDOWN}s），跳过本次切换"
            return 0
        fi
        do_switch "$want" "$cur" "$eth_res" "$wifi_res" "$se" "$sw"
    fi
}

cmd_status() {
    find_active
    local eth_gw wifi_gw eth_ip wifi_ip cur
    eth_gw="$(svc_router "$ACTIVE_ETH_SVC")"
    wifi_gw="$(svc_router "$ACTIVE_WIFI_SVC")"
    eth_ip="$(dev_ipv4 "$ACTIVE_ETH_DEV")"
    wifi_ip="$(dev_ipv4 "$ACTIVE_WIFI_DEV")"
    cur="$(default_dev)"

    echo "=== macOS 智能选路状态  $(ts) ==="
    printf '%-10s %-8s %-16s %-16s %s\n' "角色" "设备" "IPv4" "网关" "服务名"
    printf '%-10s %-8s %-16s %-16s %s\n' "以太网" "${ACTIVE_ETH_DEV:--}" "${eth_ip:--}" "${eth_gw:--}" "${ACTIVE_ETH_SVC:--}"
    printf '%-10s %-8s %-16s %-16s %s\n' "Wi-Fi" "${ACTIVE_WIFI_DEV:--}" "${wifi_ip:--}" "${wifi_gw:--}" "${ACTIVE_WIFI_SVC:--}"
    echo
    echo "当前默认路由 : ${cur:-未知} via $(default_gw)"
    echo "选路模式     : $MODE"
    echo "判定结果     : eth_ok=$(state_get eth_ok) wifi_ok=$(state_get wifi_ok) streak_eth=$(state_get streak_eth) streak_wifi=$(state_get streak_wifi)"
    echo "最近切换     : $(human_ts "$(state_get last_switch)")（累计 $(state_get switch_count) 次）"
    echo
    echo "服务顺序（* 为禁用，越靠前越优先）："
    networksetup -listnetworkserviceorder 2>/dev/null | grep -v '^An asterisk' | sed '/^[[:space:]]*$/d;s/^/  /'
    echo
    if [ "$(id -u)" -ne 0 ]; then
        echo "提示：未使用 sudo 运行，探测只能按“当前默认路由”进行，仅供参考。"
    fi
    if [ -n "$eth_ip" ] && [ -n "$wifi_ip" ]; then
        local a b
        a=$(printf '%s' "$eth_ip"  | cut -d. -f1-3)
        b=$(printf '%s' "$wifi_ip" | cut -d. -f1-3)
        if [ "$a" = "$b" ]; then
            echo "${C_WARN}⚠️  两个接口处于同一 /24 网段（$a.x），路由可能互相干扰，建议修改局域网网段。${C_RST}"
        fi
    fi
    if [ -n "$ACTIVE_ETH_SVC" ] && ! svc_enabled "$ACTIVE_ETH_SVC"; then
        echo "${C_WARN}⚠️  以太网服务“$ACTIVE_ETH_SVC”已被禁用，插网线也不会启用。${C_RST}"
    fi
}

cmd_test() {
    local verbose=0
    case "$1" in -v|--verbose) verbose=1 ;; esac
    if [ "$(id -u)" -ne 0 ]; then
        echo "提示：非 root 运行，只能按“当前默认路由”探测，建议使用 sudo smartroute test"
    fi
    find_active
    local eth_res="na" wifi_res="na" eth_detail="" wifi_detail=""
    [ -n "$ACTIVE_ETH_DEV" ]  && { eth_res="$(probe_dev "$ACTIVE_ETH_DEV" "$(svc_router "$ACTIVE_ETH_SVC")")"; eth_detail="$(cat "$PROBE_DETAIL_FILE" 2>/dev/null)"; }
    [ -n "$ACTIVE_WIFI_DEV" ] && { wifi_res="$(probe_dev "$ACTIVE_WIFI_DEV" "$(svc_router "$ACTIVE_WIFI_SVC")")"; wifi_detail="$(cat "$PROBE_DETAIL_FILE" 2>/dev/null)"; }
    echo "以太网 (${ACTIVE_ETH_DEV:-无})   : $eth_res"
    if [ "$verbose" = "1" ] && [ -n "$eth_detail" ]; then echo "    └─ $eth_detail"; fi
    echo "Wi-Fi  (${ACTIVE_WIFI_DEV:-无})   : $wifi_res"
    if [ "$verbose" = "1" ] && [ -n "$wifi_detail" ]; then echo "    └─ $wifi_detail"; fi
    return 0
}

cmd_set() {
    local kv="$1" key val target
    if [ -z "$kv" ]; then
        echo "用法: smartroute set auto|ethernet|wifi"
        echo "  或: smartroute set KEY=VALUE  （KEY 见 config 命令输出）"
        exit 1
    fi
    case "$kv" in
        auto)          key="MODE"; val="auto" ;;
        ethernet|eth)  key="MODE"; val="ethernet" ;;
        wifi|wlan)     key="MODE"; val="wifi" ;;
        *=*)           key="${kv%%=*}"; val="${kv#*=}" ;;
        *) echo "无法识别: $kv"; exit 1 ;;
    esac

    # 校验配置项
    case " $VALID_KEYS " in
        *" $key "*) ;;
        *) echo "不支持的配置项: $key"; echo "可用: $VALID_KEYS"; exit 1 ;;
    esac
    case "$key" in
        MODE)
            case "$val" in auto|ethernet|wifi) ;; *) echo "MODE 只能是 auto|ethernet|wifi"; exit 1 ;; esac ;;
        OK_N|FAIL_N|COOLDOWN|PING_TIMEOUT|NC_TIMEOUT)
            [[ "$val" =~ ^[0-9]+$ ]] || { echo "$key 必须是正整数"; exit 1; } ;;
        TLS_PROBE|NOTIFY|AUTO_WIFI_POWER|BALANCE)
            case "$val" in 0|1) ;; *) echo "$key 只能是 0 或 1"; exit 1 ;; esac ;;
    esac

    # 写入目标：优先用户级配置（普通用户可写，无需 sudo）
    if [ -w "$USER_CONF" ] || [ -w "$(dirname "$USER_CONF")" ]; then
        target="$USER_CONF"
    elif [ "$(id -u)" -eq 0 ]; then
        target="$CONF"
    else
        die "无法写入 $USER_CONF，请用 sudo: sudo smartroute set $kv"
    fi

    conf_set "$key" "$val" "$target" || die "写入 $target 失败"
    echo "已设置 $key=$val（写入 $target）"
    echo "守护进程将在下个周期（≤20 秒）生效；可 sudo smartroute watch 立即生效"
}

# 写入配置到指定文件（内部使用）
conf_set() {   # $1=KEY $2=VALUE $3=目标文件
    local key="$1" val="$2" target="$3"
    if [ -f "$target" ]; then
        grep -v "^$key=" "$target" > "$target.tmp" 2>/dev/null && mv "$target.tmp" "$target"
    else
        printf '# smartroute 用户配置（优先级高于 /etc/smartroute.conf）\n' > "$target" 2>/dev/null || return 1
    fi
    printf '%s=%s\n' "$key" "$val" >> "$target" 2>/dev/null || return 1
    return 0
}

# 内部快捷写配置（自动选择用户级/系统级）
conf_set_auto() {   # $1=KEY $2=VALUE
    if [ -w "$USER_CONF" ] || [ -w "$(dirname "$USER_CONF")" ]; then
        conf_set "$1" "$2" "$USER_CONF"
    elif [ "$(id -u)" -eq 0 ]; then
        conf_set "$1" "$2" "$CONF"
    else
        return 1
    fi
}

cmd_log() {
    local n="${1:-50}"
    if [ -f "$LOG_FILE" ]; then
        tail -n "$n" "$LOG_FILE"
    else
        echo "暂无日志（$LOG_FILE 不存在）"
    fi
}

cmd_config() {
    echo "当前生效配置（默认值 < $CONF < $USER_CONF，后者优先）"
    local k v
    for k in $VALID_KEYS; do
        eval "v=\$$k"
        printf '  %-16s = %s\n' "$k" "$v"
    done
    local f
    for f in "$USER_CONF" "$CONF"; do
        echo
        if [ -f "$f" ]; then
            echo "配置文件 $f 内容："
            sed 's/^/  /' "$f"
        else
            echo "（配置文件 $f 不存在）"
        fi
    done
}

cmd_doctor() {
    find_active
    local eth_gw wifi_gw eth_ip wifi_ip cur defgw body a b
    local advice=()
    eth_gw="$(svc_router "$ACTIVE_ETH_SVC")"
    wifi_gw="$(svc_router "$ACTIVE_WIFI_SVC")"
    eth_ip="$(dev_ipv4 "$ACTIVE_ETH_DEV")"
    wifi_ip="$(dev_ipv4 "$ACTIVE_WIFI_DEV")"
    cur="$(default_dev)"; defgw="$(default_gw)"

    echo "=== smartroute 一键体检  $(ts) ==="

    echo
    echo "[1] 网络接口"
    printf '    以太网 %-6s IP=%-15s 网关=%-15s 服务=%s\n' "${ACTIVE_ETH_DEV:-无}" "${eth_ip:--}" "${eth_gw:--}" "${ACTIVE_ETH_SVC:--}"
    printf '    Wi-Fi  %-6s IP=%-15s 网关=%-15s 服务=%s\n' "${ACTIVE_WIFI_DEV:-无}" "${wifi_ip:--}" "${wifi_gw:--}" "${ACTIVE_WIFI_SVC:--}"

    echo
    echo "[2] 默认路由与网关"
    if [ -z "$cur" ]; then
        echo "    ${C_ERR}系统没有默认路由${C_RST}"
        advice+=("系统没有默认路由：检查 系统设置→网络，确认至少一个服务是启用且已连接")
    else
        echo "    默认路由走 ${C_OK}$cur${C_RST} via ${defgw:-?}"
        if [ -n "$defgw" ]; then
            if ping -c 1 -W 1000 "$defgw" >/dev/null 2>&1; then
                echo "    网关 $defgw 可达 ${C_OK}✓${C_RST}"
            else
                echo "    网关 $defgw ${C_ERR}不可达 ✗${C_RST}（网线没插好 / 对端设备关机 / 网段配错）"
                advice+=("默认网关 $defgw ping 不通：这就是“上不了网”的直接原因")
            fi
        fi
        if [ "$cur" != "$ACTIVE_ETH_DEV" ] && [ "$cur" != "$ACTIVE_WIFI_DEV" ]; then
            echo "    ${C_WARN}注意：默认路由由 $cur（VPN/拨号等其他接口）持有，smartroute 不会干预${C_RST}"
        fi
    fi

    echo
    echo "[3] DNS 解析"
    if dscacheutil -hostname www.apple.com >/dev/null 2>&1; then
        echo "    www.apple.com 解析正常 ${C_OK}✓${C_RST}"
    else
        echo "    DNS 解析 ${C_ERR}失败 ✗${C_RST}（DNS 不可达或未配置）"
        advice+=("DNS 解析失败：尝试更换 DNS（如 223.5.5.5 / 119.29.29.29），或在 VPN 设置里检查 DNS 转发")
    fi

    echo
    echo "[4] 真实互联网访问（HTTPS，走当前默认路由）"
    if curl -s -m 5 -o /dev/null https://www.apple.com/ ; then
        echo "    https://www.apple.com 可访问 ${C_OK}✓${C_RST}"
    else
        echo "    https://www.apple.com ${C_ERR}不可访问 ✗${C_RST}"
        advice+=("HTTPS 访问失败：外网不通，结合 [2][3] 结果定位是网关、DNS 还是运营商问题")
    fi

    echo
    echo "[5] 门户/代理劫持检测（captive portal）"
    body="$(curl -s -m 5 http://captive.apple.com/hotspot-detect.html 2>/dev/null | head -c 200)"
    if printf '%s' "$body" | grep -q "Success"; then
        echo "    未检测到门户劫持 ${C_OK}✓${C_RST}"
    elif [ -n "$body" ]; then
        echo "    ${C_WARN}检测到门户/代理劫持：HTTP 被拦截，可能需要网页登录认证${C_RST}"
        advice+=("网络存在门户认证：用浏览器打开任意网页完成登录后再使用")
    else
        echo "    无法获取探测页面（当前默认路由不通）"
    fi

    echo
    echo "[6] 配置与冲突"
    if [ -n "$eth_ip" ] && [ -n "$wifi_ip" ]; then
        a=$(printf '%s' "$eth_ip"  | cut -d. -f1-3)
        b=$(printf '%s' "$wifi_ip" | cut -d. -f1-3)
        if [ "$a" = "$b" ]; then
            echo "    ${C_WARN}⚠️  以太网与 Wi-Fi 同网段（$a.x），路由会互相干扰${C_RST}"
            advice+=("两个接口同一网段：修改路由器 LAN 网段（如改成 192.168.2.x），或只用一个接口")
        else
            echo "    网段无冲突（eth=$a.x wifi=$b.x）${C_OK}✓${C_RST}"
        fi
    else
        echo "    只有一个接口活跃，无网段冲突"
    fi
    if [ -n "$ACTIVE_ETH_SVC" ] && ! svc_enabled "$ACTIVE_ETH_SVC"; then
        echo "    ${C_WARN}⚠️  以太网服务“$ACTIVE_ETH_SVC”被禁用，插网线也不会生效${C_RST}"
        advice+=("以太网服务被禁用：系统设置→网络 里启用“$ACTIVE_ETH_SVC”（确认要用有线时）")
    fi
    echo "    选路模式: $MODE（auto=谁有外网走谁 / ethernet=强制有线 / wifi=强制无线）"

    echo
    echo "[7] smartroute 运行状态"
    echo "    eth_ok=$(state_get eth_ok) wifi_ok=$(state_get wifi_ok) streak_eth=$(state_get streak_eth) streak_wifi=$(state_get streak_wifi)"
    echo "    最近切换: $(human_ts "$(state_get last_switch)")，累计 $(state_get switch_count) 次"
    if pgrep -f 'smartroute watch' >/dev/null 2>&1 || launchctl print system/com.user.smartroute >/dev/null 2>&1; then
        echo "    守护进程: 运行中 ${C_OK}✓${C_RST}"
    else
        echo "    守护进程: ${C_WARN}未检测到（未安装或已停止）${C_RST}"
        advice+=("守护进程未运行：cd ~/Pictures/smartroute && sudo bash install.sh")
    fi

    echo
    if [ "${#advice[@]}" -gt 0 ]; then
        echo "建议："
        local a
        for a in "${advice[@]}"; do echo "  - $a"; done
    else
        echo "${C_OK}未发现明显问题，网络看起来正常。${C_RST}"
    fi
}

# ---------------- 子网/掩码工具 ----------------

dev_prefix() {   # $1=十六进制掩码(0xffffff00) -> 前缀长度(24)；不规则掩码返回空
    local hex="${1#0x}" bits=0 i seg
    [ ${#hex} -eq 8 ] || return 1
    for i in 1 3 5 7; do
        seg="$(printf '%s' "$hex" | cut -c$i-$((i+1)))"
        case "$seg" in
            ff) bits=$((bits+8)) ;;
            fe) bits=$((bits+7)) ;;
            fc) bits=$((bits+6)) ;;
            f8) bits=$((bits+5)) ;;
            f0) bits=$((bits+4)) ;;
            e0) bits=$((bits+3)) ;;
            c0) bits=$((bits+2)) ;;
            80) bits=$((bits+1)) ;;
            00) ;;
            *) return 1 ;;
        esac
    done
    echo "$bits"
}

dev_subnet() {   # $1=设备 -> "192.168.1.0/24"（取不到返回空）
    local info ip mask prefix a b c d m m1 m2 m3 m4
    info="$(ifconfig "$1" 2>/dev/null | awk '/^[ \t]*inet /{print $2, $4; exit}')"
    [ -n "$info" ] || return 0
    ip="${info% *}"; mask="${info#* }"
    case "$mask" in 0x*) ;; *) return 0 ;; esac
    prefix="$(dev_prefix "$mask")"
    [ -n "$prefix" ] || return 0
    IFS=. read -r a b c d <<< "$ip"
    [ -n "$a" ] && [ -n "$d" ] || return 0
    m=0; local i=0
    while [ $i -lt "$prefix" ]; do m=$((m*2+1)); i=$((i+1)); done
    while [ $i -lt 32 ]; do m=$((m*2)); i=$((i+1)); done
    m1=$(( m / 16777216 % 256 )); m2=$(( m / 65536 % 256 )); m3=$(( m / 256 % 256 )); m4=$(( m % 256 ))
    echo "$(( a & m1 )).$(( b & m2 )).$(( c & m3 )).$(( d & m4 ))/$prefix"
}

cidr_netstat() {   # $1=CIDR -> netstat -rn 里的目的地写法（仅 /8 /16 /24，其他原样返回）
    local ip="${1%/*}" p="${1#*/}" a b c d
    IFS=. read -r a b c d <<< "$ip"
    case "$p" in
        8)  echo "$a/8" ;;
        16) echo "$a.$b/16" ;;
        24) echo "$a.$b.$c" ;;
        *)  echo "$1" ;;
    esac
}

# ---------------- 分流规则（静态路由，普通用户可写、守护进程应用） ----------------

route_add_net() {   # $1=CIDR $2=设备 $3=网关
    route add -net "$1" "$3" 2>/dev/null && return 0
    route add -net "$1" -interface "$2" "$3" 2>/dev/null && return 0
    return 1
}

route_del_net() {   # $1=CIDR $2=设备
    route delete -net "$1" -interface "$2" 2>/dev/null && return 0
    route delete -net "$1" 2>/dev/null && return 0
    return 1
}

route_has() {   # $1=CIDR $2=设备 -> 0 已存在
    local want
    want="$(cidr_netstat "$1")"
    netstat -rn -f inet 2>/dev/null | awk -v d="$want" -v dev="$2" '
        $1==d && $NF==dev { found=1 }
        END { exit found ? 0 : 1 }'
}

apply_rules() {   # 由守护进程调用：把规则文件落地为静态路由
    [ "$(id -u)" -eq 0 ] || return 0
    local want="" applied line cidr dev gw entry ifs
    applied="$(state_get applied_routes)"

    if [ -f "$RULES_FILE" ]; then
        while read -r cidr dev extra; do
            case "$cidr" in ""|\#*) continue ;; esac
            [ -n "$dev" ] || continue
            want="$want$cidr@$dev;"
        done < "$RULES_FILE"
    fi

    # 删除已应用但规则里没有的
    ifs="$IFS"; IFS=';'
    for entry in $applied; do
        [ -n "$entry" ] || continue
        case "$want" in
            *"$entry;"*) ;;
            *) cidr="${entry%@*}"; dev="${entry#*@}"
               route_del_net "$cidr" "$dev" && log "分流规则: 删除路由 $cidr via $dev" ;;
        esac
    done
    # 添加规则里有但还没生效的
    for entry in $want; do
        [ -n "$entry" ] || continue
        cidr="${entry%@*}"; dev="${entry#*@}"
        route_has "$cidr" "$dev" && continue
        if dev_active "$dev"; then
            gw="$(svc_router "$(svc_of_dev "$dev")")"
            if [ -n "$gw" ] && route_add_net "$cidr" "$dev" "$gw"; then
                log "分流规则: 添加路由 $cidr via $dev (gw $gw)"
            fi
        fi
    done
    IFS="$ifs"

    state_set applied_routes "$want"
    return 0
}

cmd_rule() {
    local sub="${1:-list}"
    case "$sub" in
        add)
            local cidr="$2" dev="$3"
            [ -n "$cidr" ] && [ -n "$dev" ] || die "用法: smartroute rule add <CIDR> <接口>
例: smartroute rule add 10.0.0.0/8 en0   （公司内网段走有线）"
            printf '%s' "$cidr" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$' \
                || die "CIDR 格式不正确: $cidr（例 10.0.0.0/8）"
            local pfx="${cidr#*/}"
            [ "$pfx" -ge 1 ] && [ "$pfx" -le 32 ] || die "前缀长度必须在 1..32"
            hardware_ports | awk -F'\t' -v d="$dev" '$2==d{f=1} END{exit f?0:1}' \
                || die "没有这个接口: $dev（用 smartroute status 查看可用接口）"
            mkdir -p "$(dirname "$RULES_FILE")" 2>/dev/null
            if [ ! -f "$RULES_FILE" ]; then
                printf '# smartroute 分流规则：每行 "CIDR 接口"，守护进程（root）自动应用\n' > "$RULES_FILE" 2>/dev/null \
                    || die "无法创建 $RULES_FILE"
            fi
            grep -v "^$cidr[[:space:]]" "$RULES_FILE" > "$RULES_FILE.tmp" 2>/dev/null && mv "$RULES_FILE.tmp" "$RULES_FILE"
            printf '%s %s\n' "$cidr" "$dev" >> "$RULES_FILE" || die "写入 $RULES_FILE 失败"
            echo "已添加规则: $cidr -> $dev"
            echo "守护进程将在 ≤20 秒内应用；可 sudo smartroute watch 立即应用"
            ;;
        del|rm)
            local cidr="$2"
            [ -n "$cidr" ] || die "用法: smartroute rule del <CIDR>"
            [ -f "$RULES_FILE" ] || die "规则文件不存在（$RULES_FILE）"
            grep -v "^$cidr[[:space:]]" "$RULES_FILE" > "$RULES_FILE.tmp" 2>/dev/null && mv "$RULES_FILE.tmp" "$RULES_FILE"
            echo "已删除规则: $cidr"
            echo "守护进程将在 ≤20 秒内移除对应路由；可 sudo smartroute watch 立即生效"
            ;;
        list|"")
            echo "分流规则（$RULES_FILE）："
            local applied entry cidr dev mark any=0
            applied="$(state_get applied_routes)"
            if [ -f "$RULES_FILE" ]; then
                while read -r cidr dev extra; do
                    case "$cidr" in ""|\#*) continue ;; esac
                    [ -n "$dev" ] || continue
                    any=1
                    mark="未应用"
                    case ";$applied" in
                        *";$cidr@$dev;"*)
                            if route_has "$cidr" "$dev"; then mark="已生效"; else mark="等待应用"; fi ;;
                    esac
                    printf '  %-20s -> %-8s [%s]\n' "$cidr" "$dev" "$mark"
                done < "$RULES_FILE"
            fi
            [ "$any" -eq 0 ] && echo "  （无规则）"
            echo
            echo "提示: 例 smartroute rule add 10.0.0.0/8 en0 让公司内网段固定走有线"
            ;;
        *) die "未知子命令: $sub（可用 add/del/list）" ;;
    esac
}

# ---------------- 网速与质量 ----------------

cmd_stats() {   # 输出各活跃接口的累计字节（App 用来算实时速率）
    local port dev line
    printf 'time=%s\n' "$(date +%s)"
    while IFS="	" read -r port dev; do
        [ -n "$dev" ] || continue
        dev_active "$dev" || continue
        line="$(netstat -I "$dev" -b 2>/dev/null | sed -n '2p')"
        [ -n "$line" ] || continue
        set -- $line
        # $1=Name $2=Mtu $3=Network $4=Address $5=Ipkts $6=Ierrs $7=Ibytes $8=Opkts $9=Oerrs $10=Obytes
        printf '%s ibytes=%s obytes=%s ipkts=%s opkts=%s\n' "$dev" "${7:-0}" "${10:-0}" "${5:-0}" "${8:-0}"
    done < <(hardware_ports)
    return 0
}

cmd_quality() {   # 每接口 6 个包测延迟/丢包（root 强制走该接口，非 root 只能测默认路由）
    local role dev svc gw out loss rtt min avg max rest via
    find_active
    for role in eth wifi; do
        if [ "$role" = "eth" ]; then dev="$ACTIVE_ETH_DEV"; svc="$ACTIVE_ETH_SVC"
        else dev="$ACTIVE_WIFI_DEV"; svc="$ACTIVE_WIFI_SVC"; fi
        [ -n "$dev" ] || continue
        dev_active "$dev" || continue
        gw="$(svc_router "$svc")"
        via="default"
        if [ "$(id -u)" -eq 0 ] && [ -n "$gw" ]; then
            if route_add_host "223.5.5.5" "$dev" "$gw"; then via="hostroute"; fi
        fi
        out="$(ping -c 6 -W 800 223.5.5.5 2>/dev/null)"
        [ "$via" = "hostroute" ] && route delete -host "223.5.5.5" -interface "$dev" 2>/dev/null
        # "6 packets transmitted, 6 received, 0.0% packet loss" → 取带 % 的那一项
        loss="$(printf '%s' "$out" | awk '/packet loss/{for(i=1;i<=NF;i++) if($i ~ /%$/) print $i}')"
        rtt="$(printf '%s' "$out" | awk -F' = ' '/round-trip/{print $2}')"
        min="${rtt%%/*}"; rest="${rtt#*/}"; avg="${rest%%/*}"; rest="${rest#*/}"; max="${rest%%/*}"
        printf '%s dev=%s via=%s loss=%s min=%s avg=%s max=%s\n' \
            "$role" "$dev" "$via" "${loss:-?}" "${min:-?}" "${avg:-?}" "${max:-?}"
    done
    return 0
}

# ---------------- 双网并发（pf 轮询分流） ----------------

pf_enabled() {   # 0=开启 1=关闭 2=未知（无权限）
    local out
    out="$(pfctl -s info 2>/dev/null)"
    case "$out" in
        *"Status: Enabled"*)  return 0 ;;
        *"Status: Disabled"*) return 1 ;;
        *) return 2 ;;
    esac
}

pf_anchor_loaded() { pfctl -a "$PF_ANCHOR" -s rules 2>/dev/null | grep -q .; }

pf_enabled_by_us() {   # 系统 pf 是不是我们打开的（决定撤销时是否关闭 pf）
    [ -f "$PF_STATE_FILE" ] && grep -q "pf_enabled_by_us=1" "$PF_STATE_FILE" 2>/dev/null
}

vpn_holds_default() {   # 默认路由是否在 VPN/拨号接口上
    local d
    d="$(default_dev)"
    case "$d" in
        utun*|ppp*|ipsec*|tun*|tap*) return 0 ;;
        *) return 1 ;;
    esac
}

# 全流量 VPN：默认路由或 0/1 + 128/1 拆分路由由 VPN 持有，此时无法安全分流
vpn_full_tunnel() {
    netstat -rn -f inet 2>/dev/null | awk '
        $NF ~ /^(utun|ppp|ipsec|tun|tap)/ && ($1 == "default" || $1 == "0/1" || $1 == "128/1") { found = 1 }
        END { exit found ? 0 : 1 }'
}

# 输出需要排除的网段（VPN/拨号接口上的路由），每行一个 CIDR
other_nets() {
    netstat -rn -f inet 2>/dev/null | awk '
        $NF ~ /^(utun|ppp|ipsec|tun|tap)/ {
            d = $1
            if (d ~ /\//) {
                n = substr(d, index(d, "/") + 1)
                ip = substr(d, 1, index(d, "/") - 1)
            } else {
                ip = d
                m = split(ip, p, ".")
                n = (m == 4) ? 32 : (m == 3) ? 24 : (m == 2) ? 16 : 8
            }
            m = split(ip, p, ".")
            for (i = m + 1; i <= 4; i++) p[i] = "0"
            print p[1] "." p[2] "." p[3] "." p[4] "/" n
        }' | sort -u
}

write_pf_rules() {   # $1=设备A $2=网关A $3=设备B $4=网关B $5=额外排除网段（空格分隔，可空）
    local d1="$1" gw1="$2" d2="$3" gw2="$4" excl="$5"
    local lan1 lan2 same=0
    lan1="$(dev_subnet "$d1")"; lan2="$(dev_subnet "$d2")"
    if [ -n "$lan1" ] && [ "$lan1" = "$lan2" ]; then same=1; fi
    mkdir -p "$(dirname "$PF_ANCHOR_FILE")" 2>/dev/null || return 1
    {
        echo "# smartroute 双网并发分流规则 —— 由 'smartroute balance on' 自动生成"
        echo "# 撤销: sudo smartroute balance off"
        echo "ext1 = \"$d1\""
        echo "gw1  = \"$gw1\""
        echo "ext2 = \"$d2\""
        echo "gw2  = \"$gw2\""
        if [ "$same" = "1" ]; then
            echo "# 两个接口在同一网段（$lan1），源地址天然合法，不需要 NAT"
            echo "lan_all = \"{ $lan1 $excl 169.254.0.0/16 224.0.0.0/4 127.0.0.0/8 ff02::/16 }\""
            echo "pass out inet proto { tcp udp } from any to ! \$lan_all route-to { (\$ext1 \$gw1) (\$ext2 \$gw2) } round-robin"
        else
            echo "# 两个接口在不同网段，按出口接口修正源地址，否则对端网关会丢弃"
            echo "lan_all = \"{ $lan1 $lan2 $excl 169.254.0.0/16 224.0.0.0/4 127.0.0.0/8 ff02::/16 }\""
            echo "match out on \$ext1 inet from ! \$lan_all to ! \$lan_all nat-to (\$ext1)"
            echo "match out on \$ext2 inet from ! \$lan_all to ! \$lan_all nat-to (\$ext2)"
            echo "pass out inet proto { tcp udp } from any to ! \$lan_all route-to { (\$ext1 \$gw1) (\$ext2 \$gw2) } round-robin"
        fi
        if [ -n "$excl" ]; then
            echo "# 已排除 VPN/拨号网段: $excl"
        fi
    } > "$PF_ANCHOR_FILE" || return 1
    return 0
}

balance_off() {   # $1=quiet 时不输出（安全阀内部调用）
    local q="${1:-}"
    if [ "$(id -u)" -eq 0 ]; then
        pfctl -a "$PF_ANCHOR" -F all 2>/dev/null
        rm -f "$PF_ANCHOR_FILE" 2>/dev/null
        if pf_enabled_by_us; then
            pfctl -d 2>/dev/null && log "双网并发: 关闭由 smartroute 开启的系统 pf"
        fi
        rm -f "$PF_STATE_FILE" 2>/dev/null
        log "双网并发分流已关闭，网络恢复原状"
    fi
    conf_set_auto BALANCE 0
    [ "$q" = "quiet" ] || echo "双网并发分流已关闭，网络已恢复原状"
    return 0
}

balance_validate() {   # $1=设备A $2=IP-A $3=设备B $4=IP-B -> 0 验证通过
    local d1="$1" i1="$2" d2="$3" i2="$4" i ip ok=0 need=10
    local b1a b2a b1b b2b c1 c2
    # 记录测试前的计数器
    b1a="$(netstat -I "$d1" -b 2>/dev/null | sed -n '2p' | awk '{print $7}')"
    b2a="$(netstat -I "$d2" -b 2>/dev/null | sed -n '2p' | awk '{print $7}')"
    # 10 个不同目标，要求全部连通
    for i in 1 2 3 4 5 6 7 8 9 10; do
        ip="$((i*11%250+1)).$((i*29%250+1)).$((i*37%250+1)).$((i*53%250+1))"
        curl -s -m 6 -o /dev/null "https://$ip/" 2>/dev/null && ok=$((ok+1))
    done
    if [ "$ok" -lt "$need" ]; then
        log "并发分流验证失败: 连通性 $ok/$need"
        echo "验证失败：10 个测试连接只有 $ok 个成功，已自动还原" >&2
        return 1
    fi
    # 分布检查：先看 NAT 计数器（按接口 IP 匹配），没有 NAT 规则时退化为字节增量
    c1="$(pfctl -s nat 2>/dev/null | awk -v a="$i1" '
        /nat-to|rdr-to/ { f = (index($0, a) > 0) }
        /Packets:/ { if (f) { if (match($0, /Packets: [0-9]+/)) s += substr($0, RSTART+9, RLENGTH-9) + 0; f = 0 } }
        END { print s + 0 }')"
    c2="$(pfctl -s nat 2>/dev/null | awk -v a="$i2" '
        /nat-to|rdr-to/ { f = (index($0, a) > 0) }
        /Packets:/ { if (f) { if (match($0, /Packets: [0-9]+/)) s += substr($0, RSTART+9, RLENGTH-9) + 0; f = 0 } }
        END { print s + 0 }')"
    if [ "$c1" = "0" ] && [ "$c2" = "0" ]; then
        # 没有 NAT 规则（同网段场景），退化为字节增量检查
        b1b="$(netstat -I "$d1" -b 2>/dev/null | sed -n '2p' | awk '{print $7}')"
        b2b="$(netstat -I "$d2" -b 2>/dev/null | sed -n '2p' | awk '{print $7}')"
        if [ -n "$b1b" ] && [ -n "$b2b" ] && [ -n "$b1a" ] && [ -n "$b2a" ]; then
            if [ $((b2b - b2a)) -le 0 ]; then
                log "并发分流验证失败: $d2 字节数无增长，分流可能未生效"
                echo "验证失败：$d2 没有产生流量，已自动还原" >&2
                return 1
            fi
        fi
    elif [ "$c1" = "0" ] || [ "$c2" = "0" ]; then
        log "并发分流验证失败: NAT 分布不均 ($d1=$c1 $d2=$c2)"
        echo "验证失败：流量没有分布到两个接口（$d1=$c1, $d2=$c2），已自动还原" >&2
        return 1
    fi
    log "并发分流验证通过: 连通性 $ok/$need, NAT 分布 $d1=$c1 $d2=$c2"
    return 0
}

balance_on() {
    [ "$(id -u)" -eq 0 ] || die "双网并发需要 root: sudo smartroute balance on"
    command -v pfctl >/dev/null 2>&1 || die "系统缺少 pfctl"
    vpn_holds_default && die "检测到 VPN/拨号接口持有默认路由，暂不支持并发分流（会穿透 VPN）"
    if vpn_full_tunnel; then
        die "检测到全流量 VPN（默认路由或 0/1+128/1 由 VPN 持有），无法安全分流，请先断开 VPN"
    fi

    find_active
    [ -n "$ACTIVE_ETH_DEV" ]  || die "没有检测到活跃的以太网接口"
    [ -n "$ACTIVE_WIFI_DEV" ] || die "没有检测到活跃的 Wi-Fi 接口"
    local eth_gw wifi_gw eth_res wifi_res
    eth_gw="$(svc_router "$ACTIVE_ETH_SVC")"; wifi_gw="$(svc_router "$ACTIVE_WIFI_SVC")"
    [ -n "$eth_gw" ]  || die "取不到以太网网关（服务: ${ACTIVE_ETH_SVC:-?}）"
    [ -n "$wifi_gw" ] || die "取不到 Wi-Fi 网关（服务: ${ACTIVE_WIFI_SVC:-?}）"

    echo "正在检测两个接口的外网连通性…"
    eth_res="$(probe_dev "$ACTIVE_ETH_DEV" "$eth_gw")"
    wifi_res="$(probe_dev "$ACTIVE_WIFI_DEV" "$wifi_gw")"
    if [ "$eth_res" != "ok" ] || [ "$wifi_res" != "ok" ]; then
        die "双网并发要求两个接口都有外网（当前 以太网=$eth_res Wi-Fi=$wifi_res）"
    fi

    # 必须能确定两个接口的网段，否则生成的排除规则不完整（会误伤局域网），宁可不开
    local lan1 lan2
    lan1="$(dev_subnet "$ACTIVE_ETH_DEV")"; lan2="$(dev_subnet "$ACTIVE_WIFI_DEV")"
    if [ -z "$lan1" ] || [ -z "$lan2" ]; then
        die "无法确定接口网段（$ACTIVE_ETH_DEV=${lan1:-未知} / $ACTIVE_WIFI_DEV=${lan2:-未知}），为安全起见不开启并发分流"
    fi

    # 排除 VPN/拨号网段，避免分流把 VPN 流量送到物理接口
    local excl
    excl="$(other_nets | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    if [ -n "$excl" ]; then
        echo "检测到 VPN/拨号网段，将排除: $excl"
    fi

    echo "生成分流规则: $ACTIVE_ETH_DEV($lan1, gw $eth_gw) <-> $ACTIVE_WIFI_DEV($lan2, gw $wifi_gw)"
    write_pf_rules "$ACTIVE_ETH_DEV" "$eth_gw" "$ACTIVE_WIFI_DEV" "$wifi_gw" "$excl" \
        || die "无法写入 $PF_ANCHOR_FILE"

    # 记录系统 pf 原状态，便于撤销时还原
    if pf_enabled; then
        echo "pf_enabled_by_us=0" > "$PF_STATE_FILE" 2>/dev/null
    else
        pfctl -e 2>/dev/null
        echo "pf_enabled_by_us=1" > "$PF_STATE_FILE" 2>/dev/null
        log "双网并发: 系统 pf 原为关闭，已由 smartroute 开启（撤销时会关闭）"
    fi
    pfctl -a "$PF_ANCHOR" -f "$PF_ANCHOR_FILE" 2>/dev/null \
        || { balance_off quiet; die "加载 pf 规则失败，已还原"; }

    echo "正在验证分流效果（10 个测试连接）…"
    if ! balance_validate "$ACTIVE_ETH_DEV" "$(dev_ipv4 "$ACTIVE_ETH_DEV")" \
                         "$ACTIVE_WIFI_DEV" "$(dev_ipv4 "$ACTIVE_WIFI_DEV")"; then
        balance_off quiet
        die "并发分流未通过验证，已自动还原（详见 sudo smartroute log）"
    fi

    conf_set_auto BALANCE 1
    log "双网并发分流已开启: $ACTIVE_ETH_DEV <-> $ACTIVE_WIFI_DEV"
    echo
    echo "✅ 双网并发已开启：新连接会在两个接口间轮询分流"
    echo "   • 多连接/多应用（浏览、下载、云同步）会分摊到两个接口"
    echo "   • 单线程下载不会翻倍（单个连接固定走一个接口）"
    echo "   • 任一口失去外网会自动关闭并发并还原（见守护进程安全阀）"
    echo "   • 撤销: sudo smartroute balance off"
    return 0
}

cmd_balance() {
    case "${1:-status}" in
        on|enable|start)  balance_on ;;
        off|disable|stop) balance_off ;;
        status|st)        balance_status ;;
        *) die "用法: smartroute balance on|off|status" ;;
    esac
}

balance_status() {
    echo "=== 双网并发（pf 分流）状态  $(ts) ==="
    pf_enabled
    case $? in
        0) echo "  系统 pf        : 开启" ;;
        1) echo "  系统 pf        : 关闭" ;;
        *) echo "  系统 pf        : 未知（无权限读取，请用 sudo smartroute balance status）" ;;
    esac
    if pf_anchor_loaded; then
        echo "  分流规则       : 已加载（$PF_ANCHOR_FILE）"
    elif [ -f "$PF_ANCHOR_FILE" ]; then
        echo "  分流规则       : 文件存在但未加载"
    else
        echo "  分流规则       : 未生成"
    fi
    if pf_enabled_by_us; then
        echo "  pf 来源        : smartroute 开启（撤销时会关闭系统 pf）"
    else
        echo "  pf 来源        : 系统原有（撤销时不动系统 pf）"
    fi
    echo "  配置开关       : BALANCE=$BALANCE"
    if [ -f "$PF_ANCHOR_FILE" ]; then
        echo "  规则内容       :"
        sed 's/^/    /' "$PF_ANCHOR_FILE" | grep -v '^    #' | sed '/^    $/d'
    fi
    echo
    echo "  原理: 新连接按轮询在两个网关间分流（不同连接走不同接口）"
    echo "  限制: 单线程传输不会加速；IPv6 流量不受影响；VPN 默认路由下不可用"
    return 0
}

# ---------------- 入口 ----------------
[ "$(uname -s)" = "Darwin" ] || die "本工具仅支持 macOS"

trap 'cleanup_probe_routes >/dev/null 2>&1; rm -rf "$LOCK_DIR" 2>/dev/null; rm -f "$PROBE_DETAIL_FILE" 2>/dev/null' EXIT INT TERM

acquire_lock() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        local pid
        pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            exit 0   # 已有实例在运行
        fi
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    fi
    echo $$ > "$LOCK_DIR/pid"
}

main() {
    local cmd="${1:-watch}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        watch|once|run) acquire_lock; cmd_watch ;;
        status|st)      cmd_status ;;
        test|check)     cmd_test "$@" ;;
        doctor|dr)      cmd_doctor ;;
        config|conf)    cmd_config ;;
        set)            cmd_set "$@" ;;
        log)            cmd_log "$@" ;;
        balance|bal)    cmd_balance "$@" ;;
        rule)           cmd_rule "$@" ;;
        stats)          cmd_stats ;;
        quality|q)      cmd_quality ;;
        -h|--help|help) usage ;;
        *)              usage ;;
    esac
}

main "$@"

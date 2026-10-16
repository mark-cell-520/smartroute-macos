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
BALANCE_MODE="round-robin"  # 并发分流策略: round-robin=两个接口轮询 | fastest=只走延迟最低的接口
FASTEST_SWITCH_RATIO=20     # 判定"明显更快"的延迟差阈值（百分比）。低于这个差距就继续轮询，
                            # 避免在两条差不多的线路间来回切
FASTEST_RECHECK=12          # fastest 模式下守护进程重新测延迟的轮询次数（每轮约 20 秒）
WIFI_FAILOVER=0             # Wi-Fi 上不了网时，自动试连其它已保存的 Wi-Fi（1 开启）
WIFI_PREFERRED=""           # 优先试连的 Wi-Fi 名（逗号分隔，靠前优先）。留空=按系统保存顺序
WIFI_FAILOVER_COOLDOWN=120  # Wi-Fi 故障转移的最小间隔（秒），防止在网络间来回跳
SPEED_TEST_URL="https://speed.cloudflare.com/__down?bytes=5000000"   # 网速优先模式的测速地址
SPEED_TEST_TIMEOUT=8        # 单次测速超时（秒）
SPEED_RECHECK=300           # 多久重新测一次网速（秒）。测速要真下载，太频繁费流量
LATENCY_RECHECK=60          # 多久重新测一次延迟（秒）
SPEED_SWITCH_RATIO=30       # 判定"明显更快"的吞吐差阈值（百分比）。低于它就继续用当前线路，
                            # 避免在两条差不多的线路间来回切

# 可用 set 命令修改的配置项
VALID_KEYS="MODE OK_N FAIL_N COOLDOWN PROBE_TARGETS PING_TIMEOUT NC_TIMEOUT TLS_PROBE NOTIFY AUTO_WIFI_POWER BALANCE BALANCE_MODE FASTEST_SWITCH_RATIO WIFI_FAILOVER WIFI_PREFERRED WIFI_FAILOVER_COOLDOWN SPEED_TEST_URL SPEED_TEST_TIMEOUT SPEED_RECHECK LATENCY_RECHECK SPEED_SWITCH_RATIO FASTEST_RECHECK"

CONF="/etc/smartroute.conf"                     # 系统级配置（root 维护，install.sh 生成）
USER_CONF="/Users/Shared/smartroute.conf"       # 用户级配置（App/普通用户可写，优先级更高）
RULES_FILE="/Users/Shared/smartroute.rules"     # 分流规则（每行: CIDR 接口，普通用户可写，守护进程应用）
STATE_FILE="/var/db/smartroute/state"
LOG_FILE="/var/log/smartroute.log"
LOCK_DIR="/var/run/smartroute.lock"
PF_ANCHOR="com.apple/smartroute"              # pf 锚点名：挂在系统 pf.conf 已有的
                                              # anchor "com.apple/*" 通配锚点下，
                                              # 无需改动 /etc/pf.conf 即可生效
PF_ANCHOR_FILE="/etc/pf.anchors/com.user.smartroute"   # 规则文件（路径与锚点名无关）
PF_STATE_FILE="/var/db/smartroute/pf.state"     # 记录我们是否开启了系统 pf（用于还原）

[ -r "$CONF" ] && . "$CONF"                    # 系统级：root 维护，install.sh 生成，可信
# 用户级配置的加载挪到 conf_parse_file 定义之后（bash 要求函数先定义再调用）

# ---------------- 基础函数 ----------------
ts()  { date '+%Y-%m-%d %H:%M:%S'; }

# 按 key 校验单个配置值（写入和解析共用）。$1=key $2=value -> 0 合法
conf_value_ok() {
    local key="$1" val="$2"
    case "$key" in
        MODE)          case "$val" in auto|ethernet|wifi|speed|latency) ;; *) return 1 ;; esac ;;
        BALANCE_MODE)  case "$val" in round-robin|fastest) ;; *) return 1 ;; esac ;;
        OK_N|FAIL_N|COOLDOWN|PING_TIMEOUT|NC_TIMEOUT|FASTEST_SWITCH_RATIO|FASTEST_RECHECK|WIFI_FAILOVER_COOLDOWN|SPEED_TEST_TIMEOUT|SPEED_RECHECK|LATENCY_RECHECK|SPEED_SWITCH_RATIO)
                       case "$val" in ''|*[!0-9]*) return 1 ;; esac ;;
        TLS_PROBE|NOTIFY|AUTO_WIFI_POWER|BALANCE|WIFI_FAILOVER)
                       case "$val" in 0|1) ;; *) return 1 ;; esac ;;
        PROBE_TARGETS) case "$val" in *[!0-9.\ ]*) return 1 ;; esac ;;
        WIFI_PREFERRED) case "$val" in *[$'\n\r']*) return 1 ;; esac ;;
        SPEED_TEST_URL) [ -n "$val" ] || return 1 ;;
        *) return 1 ;;
    esac
    return 0
}

# 每个键的取值说明（错误提示用）。校验本身在 conf_value_ok，
# 这里只负责"说清楚该填什么"——两者分开，免得改提示时不小心改松了校验。
conf_value_hint() {   # $1=key -> stdout: 说明
    case "$1" in
        MODE)          echo "MODE 只能是 auto|ethernet|wifi|speed|latency" ;;
        BALANCE_MODE)  echo "BALANCE_MODE 只能是 round-robin|fastest" ;;
        OK_N|FAIL_N|COOLDOWN|PING_TIMEOUT|NC_TIMEOUT|FASTEST_SWITCH_RATIO|FASTEST_RECHECK|WIFI_FAILOVER_COOLDOWN|SPEED_TEST_TIMEOUT|SPEED_RECHECK|LATENCY_RECHECK|SPEED_SWITCH_RATIO)
                       echo "$1 必须是非负整数" ;;
        TLS_PROBE|NOTIFY|AUTO_WIFI_POWER|BALANCE|WIFI_FAILOVER)
                       echo "$1 只能是 0 或 1" ;;
        PROBE_TARGETS) echo "PROBE_TARGETS 只能是空格分隔的 IP" ;;
        WIFI_PREFERRED) echo "WIFI_PREFERRED 不能含换行" ;;
        SPEED_TEST_URL) echo "SPEED_TEST_URL 不能为空" ;;
        *) echo "不支持的配置项: $1" ;;
    esac
}

# 解析配置文件：逐行读，只认白名单键，逐值校验，**绝不 source**。
# 为什么不能用 source：USER_CONF=/Users/Shared/smartroute.conf，而 /Users/Shared
# 是 1777（世界可写 + sticky），install.sh 又从不创建这个文件。也就是说任何本地用户
# 都能创建它，而 root 守护进程每 20 秒会读一次配置文件——用 source 等于把
# "任意本地用户 → root"的门敞开（写一行 touch 就能验证）。
# 实测确认过：source 会执行文件里的任意 shell 代码。
conf_parse_file() {   # $1=文件路径
    local f="$1" line k v n=0
    [ -r "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        # 去掉行尾 CR（配置文件被 Windows 编辑器改过的情况）
        line="${line%$'\r'}"
        case "$line" in ''|\#*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        k="${line%%=*}"; v="${line#*=}"
        k="${k%%[[:space:]]*}"; k="${k##[[:space:]]}"
        # 只认白名单键
        case " $VALID_KEYS " in
            *" $k "*) ;;
            *) continue ;;
        esac
        # 值必须过校验。过不了就忽略并计数，不要让垃圾值生效，
        # 但也不能静默——计数留给调用方决定要不要提示。
        if ! conf_value_ok "$k" "$v"; then
            n=$((n+1)); continue
        fi
        eval "$k=\$v"
    done < "$f"
    return 0
}
conf_parse_file "$USER_CONF"                     # 用户级覆盖系统级

log() {
    local msg="$*"
    # 用 { } 2>/dev/null 包住：普通用户写不了 root 的日志文件时，
    # bash 会把"重定向失败"打到自己的 stderr，那样会在终端里刷一行噪音
    { printf '%s %s\n' "$(ts)" "$msg" >> "$LOG_FILE"; } 2>/dev/null
    if [ -f "$LOG_FILE" ]; then
        local sz
        sz=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        [ "$sz" -gt 1048576 ] && mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
    fi
    # launchd 的 StandardOutPath/StandardErrorPath（.out/.err）不归我们管，
    # 也没有任何轮转机制——守护进程每 20 秒写一行，实测几天就长到几百 KB 且只增不减。
    # 顺手在这里一起轮转（只有 root 能写，普通用户静默跳过）。
    local lf
    for lf in /var/log/smartroute.out /var/log/smartroute.err; do
        [ -f "$lf" ] || continue
        sz=$(stat -f%z "$lf" 2>/dev/null || echo 0)
        [ "$sz" -gt 1048576 ] && mv "$lf" "$lf.1" 2>/dev/null
    done
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
  log [N]      查看最近日志（log 40 或 log --lines 40，默认 50 行）

双网并发 / 分流:
  balance on [round-robin|fastest]
                开启双网并发分流（需 sudo；两个接口都要有外网，自动验证，失败自动还原）
                  round-robin  新连接在两个接口间轮询，带宽可叠加（默认）
                  fastest      先测两边延迟，只走更快的那条；守护进程定期重测，变慢自动改道
  balance off   关闭并发分流并恢复原状（需 sudo）
  balance status 查看并发分流状态
  fixconf      修复用户配置属主（App 提示"保存失败"时用，需 sudo）
  rule add <CIDR> <接口>   添加静态分流规则，如 rule add 10.0.0.0/8 en0（普通用户可写，守护进程应用）
  rule del <CIDR>          删除规则
  rule list                查看规则及生效情况

Wi-Fi 选择与自动故障转移:
  wifi list               列出已保存的 Wi-Fi（靠前优先，免权限）
  wifi current            当前 Wi-Fi 的信号强度与信道（免权限）
  wifi join <网络名>       连接到指定 Wi-Fi（已保存的不用输密码）
  wifi tryall             逐个试连已保存的 Wi-Fi，自动连上第一个能上网的
  wifi auto on|off|status  Wi-Fi 上不了网时自动切换到其它可用网络

监控:
  stats        各活跃接口的累计收发字节（供 App 计算实时速率）
  report       一键诊断报告（纯文本）：接口/路由/pf/配置/日志全量快照，
               适合贴给别人排查。root 下信息更全：sudo smartroute report > r.txt
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

# 以太网和 Wi-Fi 是否经同一台路由器上网（网关相同）。
# -> 0 表示相同，1 表示不同或判断不了。
#
# 为什么要单独判这个：两个接口网关相同，说明它们不是"两条 WAN"，
# 而是"一条 WAN 的两个入口"。此时双网并发（pf 轮询分流）：
#   · 不会变快：瓶颈在路由器后面那一条上游，不在入口
#   · 反而更慢：一半连接被赶到更慢的接口（本机 100M 有线 vs Wi-Fi）
#   · 还可能引入非对称路由/ARP flux 的问题
# 所以 balance_on 默认拒绝、balance_status 醒目警告。
eth_wifi_same_gateway() {
    local eg wg
    [ -n "${ACTIVE_ETH_DEV:-}" ] && [ -n "${ACTIVE_WIFI_DEV:-}" ] || return 1
    eg="$(svc_router "${ACTIVE_ETH_SVC:-}" 2>/dev/null)"
    wg="$(svc_router "${ACTIVE_WIFI_SVC:-}" 2>/dev/null)"
    [ -n "$eg" ] && [ -n "$wg" ] || return 1
    [ "$eg" = "$wg" ]
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

# AppleScript 双引号字符串的转义：先 \ 再 "。顺序不能反，
# 否则转义产生的 \ 会被二次转义。与 Privileged.swift 的转义保持一致。
as_escape() {   # $1=原文 -> stdout: 可安全放进 AppleScript 双引号串的内容
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

notify() {   # $1=标题 $2=内容
    [ "$NOTIFY" = "1" ] || return 0
    command -v osascript >/dev/null 2>&1 || return 0
    # $1/$2 必须转义。故障转移成功时 $2 是**当前连上的 Wi-Fi 名**，
    # 而 Wi-Fi 名完全由 AP 控制：SSID 可以是 foo" & (do shell script "...") & "
    # 不转义就会逃出 AppleScript 字符串，以调用方身份执行任意代码——
    # 守护进程是 root，于是恶意 AP + 一个保存过该网络的受害者 = root RCE。
    # 实测确认过注入本身可以成立。
    local t b
    t="$(as_escape "$1")"; b="$(as_escape "$2")"
    osascript -e "display notification \"$b\" with title \"$t\"" >/dev/null 2>&1
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
    route add -host "$1" -interface "$2" "$3" >/dev/null 2>&1 && return 0
    route add -host "$1" "$3" -interface "$2" >/dev/null 2>&1 && return 0
    route add -host "$1" "$3" >/dev/null 2>&1 && return 0
    # 目标路由已存在（同网段双宿主、残留路由，或与守护进程的探测并发时会出现）：
    # 已有路由的网关与本次一致，说明就是同一条上网路径，复用即可
    local cur
    cur="$(route -n get "$1" 2>/dev/null | sed -n 's/^[[:space:]]*gateway:[[:space:]]*//p' | head -1)"
    [ -n "$cur" ] && [ "$cur" = "$3" ] && return 0
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
# 输出两行：第 1 行 ok / fail / na（接口未激活），第 2 行人类可读明细。
# probe_dev 常在 $(...) 子 shell 里被调用，全局变量传不出来，所以两行都走 stdout。
# 原理：root 下给探测目标加临时主机路由强制走指定接口，从而可以探测
# “当前不是默认路由”的接口；探测完立即删除，不影响正常流量。
# 三层探测：
#   1) ping        —— 快，但可能被防火墙禁 ICMP
#   2) TCP 53/443  —— 穿透大部分禁 ping 的网络
#   3) TLS 握手    —— 识别“TCP 通但没有真正互联网”的场景（门户劫持/假链）
set_probe_detail() {   # $1=明细内容（只写全局变量）
    PROBE_DETAIL="$1"
}

# 输出探测结果：第 1 行判定（ok/fail/na），第 2 行明细。
# 不用临时文件传递——App 超时会 SIGKILL，trap 捕获不到，文件就漏在 /tmp 里
# （历史上因此积了几十个 /tmp/.smartroute.probe.* 残留）。
probe_out() {   # $1=判定 $2=明细
    printf '%s\n%s\n' "$1" "${2:-}"
}

# ---------------- 延迟测量 ----------------
# 测量某个接口到外网的平均 RTT（毫秒）。root 下给探测目标加临时主机路由强制走指定
# 接口，因此可以测"当前不是默认路由"的接口；测完立即删除，不影响正常流量。
# 输出: 平均 RTT（如 "14.3"）；测不到返回空。多个目标取平均，避免单点抖动。
measure_latency() {   # $1=设备 $2=网关 -> stdout: 平均 RTT 毫秒（如 14.3）；测不到返回空
    local dev="$1" gw="$2" t out r vals="" seen="" n=0 max=4
    [ -n "$dev" ] || return 1
    dev_active "$dev" || return 1
    # 目标去重后最多取 max 个。这个函数会被 balance status 频繁调用，
    # 目标太多命令会变慢（每个目标最坏 2×PING_TIMEOUT），把 App 拖到超时。
    for t in $PROBE_TARGETS 1.1.1.1 8.8.8.8; do
        case " $seen " in
            *" $t "*) ;;
            *) [ "$n" -ge "$max" ] && break; seen="$seen $t"; n=$((n+1)) ;;
        esac
    done
    if [ "$(id -u)" -eq 0 ] && [ -n "$gw" ]; then
        cleanup_probe_routes
        for t in $seen; do
            route_add_host "$t" "$dev" "$gw" >/dev/null 2>&1
        done
    fi
    n=0
    for t in $seen; do
        # -i 0.2 缩短包间隔：ping -c 2 默认间隔 1 秒，4 个目标要 4 秒+
        out="$(ping -c 2 -i 0.2 -W "$PING_TIMEOUT" "$t" 2>/dev/null | tail -n 1)"
        case "$out" in
            *round-trip*)
                r="$(printf '%s' "$out" | sed -n 's|.*= *[0-9.]*/\([0-9.]*\)/.*|\1|p')"
                if [ -n "$r" ]; then vals="$vals $r"; n=$((n+1)); fi
                ;;
        esac
    done
    [ "$(id -u)" -eq 0 ] && cleanup_probe_routes >/dev/null 2>&1
    [ "$n" -gt 0 ] || return 1
    printf '%s' "$vals" | awk '{s+=$1; n++} END{ printf "%.1f", s/n }'
    return 0
}

# 比较两个接口的延迟，选出更快的一方。
# 输出: 设备名；差距小于阈值时输出 tie（表示差距不明显，应继续轮询而不是单选）
pick_fastest() {   # $1=设备A $2=延迟A $3=设备B $4=延迟B -> stdout: 设备名 | tie | 空
    local d1="$1" l1="$2" d2="$3" l2="$4"
    # 只查空串不够：0 和负数也必须当"没测到"。
    # cmd_measure 会用 state_set lat_$dev 0 作废缓存，而 ensure_latency 只在
    # 测成功时覆写——测失败就留着 "0"。若把 0 当合法延迟，0ms 永远赢，
    # latency 模式会钉死在那个其实很慢（甚至已死）的接口上。
    # 这和 pick_by_speed 的 <=0 处理必须一致（以前不一致，是个真 bug）。
    case "$l1" in ''|*[!0-9.]*) ;; esac
    case "$l2" in ''|*[!0-9.]*) ;; esac
    awk -v a="$l1" -v b="$l2" -v r="$FASTEST_SWITCH_RATIO" -v d1="$d1" -v d2="$d2" 'BEGIN{
        if (a+0 <= 0 && b+0 <= 0) { exit }              # 都没测出来
        if (a+0 <= 0) { print d2; exit }                # 只有 B 有数
        if (b+0 <= 0) { print d1; exit }
        lo = (a < b ? a : b); hi = (a < b ? b : a)
        # 与 pick_by_speed 统一用严格小于：正好等于阈值时判定赢家，
        # 不一致会让"同一个差距"在两种模式下一个换一个不换。
        if (hi < lo * (100 + r) / 100) { print "tie"; exit }
        print (a < b ? d1 : d2)
    }'
    return 0
}

probe_dev() {   # $1=设备 $2=网关
    local dev="$1" gw="$2" t ok=1 added=0
    local ping_ok=0 tcp_ok=0 tls_ok=0 targets
    set_probe_detail ""
    [ -n "$dev" ] || { set_probe_detail "接口未指定"; probe_out na "接口未指定"; return; }
    dev_active "$dev" || { set_probe_detail "接口未激活/无 IP"; probe_out na "接口未激活/无 IP"; return; }

    # 探测目标去重（TLS 目标可能已在 PROBE_TARGETS 里，避免重复加同一条路由）
    targets=""
    for t in $PROBE_TARGETS 1.1.1.1 8.8.8.8; do
        case " $targets " in *" $t "*) ;; *) targets="$targets $t" ;; esac
    done
    targets="${targets# }"
    [ "$TLS_PROBE" = "1" ] || targets="$PROBE_TARGETS"

    if [ "$(id -u)" -eq 0 ] && [ -n "$gw" ]; then
        # 先清理上次被中断时残留的探测路由，保证每次探测环境干净、可重复
        cleanup_probe_routes
        for t in $targets; do
            route_add_host "$t" "$dev" "$gw" && added=$((added+1))
        done
        if [ "$added" -eq 0 ]; then
            # 网关不在线/不可达，该接口不可能有外网
            set_probe_detail "网关 $gw 不可达（无法添加主机路由）"
            probe_out fail "网关 $gw 不可达（无法添加主机路由）"; return
        fi
    elif [ -z "$gw" ]; then
        # 有 IP 但没有网关（例如 169.254 自分配地址），不可能有外网
        set_probe_detail "有 IP 但无网关（可能是 169.254 自分配地址）"
        probe_out fail "有 IP 但无网关（可能是 169.254 自分配地址）"; return
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
            if curl -s -m 4 -o /dev/null "https://$t/" 2>/dev/null; then tls_ok=1; ok=0; break; fi
        done
    fi

    [ "$added" -gt 0 ] && cleanup_probe_routes
    set_probe_detail "${PROBE_DETAIL}${PROBE_DETAIL:+；}ping=$ping_ok tcp=$tcp_ok tls=$tls_ok"
    probe_out "$([ "$ok" -eq 0 ] && echo ok || echo fail)" "$PROBE_DETAIL"
}

# ---------------- 状态持久化（跨 launchd 调用） ----------------
state_get() {
    awk -F= -v k="$1" '$1==k{print $2; exit}' "$STATE_FILE" 2>/dev/null
}

# state 文件能不能写。普通用户跑 smartroute（不是 root）时 state 在
# /var/db/smartroute/ 下属 root，写不进去。这本身不是错误——缓存只是优化，
# 写不进就每次真测/真扫。但必须**提前判断并记住**，否则每写一次就刷一条
# "Operation not permitted"，用户看到满屏红字还以为出事了。
STATE_WRITABLE=""
state_writable() {
    if [ -z "$STATE_WRITABLE" ]; then
        if mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null &&            { [ -f "$STATE_FILE" ] && [ -w "$STATE_FILE" ] || [ -w "$(dirname "$STATE_FILE")" ]; }; then
            STATE_WRITABLE=1
        else
            STATE_WRITABLE=0
        fi
    fi
    [ "$STATE_WRITABLE" = "1" ]
}

state_set() {
    state_writable || return 0
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
        *)    s=0 ;;   # 无法识别的结果（异常输出）按未知处理，不用脏值做判定
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
    local eth_res="na" wifi_res="na" _p
    # probe_dev 输出两行：第 1 行判定，第 2 行明细。这里只取判定行。
    if [ -n "$ACTIVE_ETH_DEV" ]; then
        eth_res="$(probe_dev "$ACTIVE_ETH_DEV" "$(svc_router "$ACTIVE_ETH_SVC")" | sed -n 1p)"
    fi
    if [ -n "$ACTIVE_WIFI_DEV" ]; then
        wifi_res="$(probe_dev "$ACTIVE_WIFI_DEV" "$(svc_router "$ACTIVE_WIFI_SVC")" | sed -n 1p)"
    fi

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
            log "并发分流安全阀: 以太网 ok=$eth_ok Wi-Fi ok=${wifi_ok}，自动关闭双网并发"
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
        elif [ "$(state_get balance_mode)" = "fastest" ]; then
            # 最快线路模式：周期性重测延迟，线路变慢自动改道
            local bcyc
            bcyc=$(( $(state_get balance_cycle) + 1 ))
            state_set balance_cycle "$bcyc"
            if [ "$bcyc" -ge "$FASTEST_RECHECK" ]; then
                state_set balance_cycle 0
                balance_reevaluate
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

    # 【Wi-Fi 自动故障转移】Wi-Fi 上不了网、以太网也没外网时，自动换个能上网的 Wi-Fi
    wifi_failover_if_needed "$wifi_ok" "$eth_ok" "$wifi_res"

    # 期望的首选设备
    want=""
    case "$MODE" in
        ethernet) [ "$eth_ok" -eq 1 ] && [ -n "$ACTIVE_ETH_DEV" ] && want="$ACTIVE_ETH_DEV" ;;
        wifi)     [ "$wifi_ok" -eq 1 ] && [ -n "$ACTIVE_WIFI_DEV" ] && want="$ACTIVE_WIFI_DEV" ;;
        speed)
            # 网速优先：实测吞吐大的赢。两个都上不了网时交给可用性逻辑兜底
            if [ "$eth_ok" -eq 1 ] && [ "$wifi_ok" -eq 1 ] \
               && [ -n "$ACTIVE_ETH_DEV" ] && [ -n "$ACTIVE_WIFI_DEV" ]; then
                ensure_throughput "$ACTIVE_ETH_DEV" "$ACTIVE_WIFI_DEV"
                local _se _sw _pick
                _se="$(_metric_val "speed_$ACTIVE_ETH_DEV")"
                _sw="$(_metric_val "speed_$ACTIVE_WIFI_DEV")"
                _pick="$(pick_by_speed "$ACTIVE_ETH_DEV" "$_se" "$ACTIVE_WIFI_DEV" "$_sw")"
                case "$_pick" in
                    "")   want="" ;;      # 都没测出来，保持现状更安全
                    tie)  want="$cur" ;;  # 差距不够大，别折腾
                    *)    want="$_pick" ;;
                esac
                log "网速优先: eth=$(fmt_bps "$_se") wifi=$(fmt_bps "$_sw") -> ${_pick:-保持}"
            elif [ "$eth_ok" -eq 1 ] && [ -n "$ACTIVE_ETH_DEV" ]; then
                want="$ACTIVE_ETH_DEV"
            elif [ "$wifi_ok" -eq 1 ] && [ -n "$ACTIVE_WIFI_DEV" ]; then
                want="$ACTIVE_WIFI_DEV"
            fi
            ;;
        latency)
            # 延时优先：延迟低的赢
            if [ "$eth_ok" -eq 1 ] && [ "$wifi_ok" -eq 1 ] \
               && [ -n "$ACTIVE_ETH_DEV" ] && [ -n "$ACTIVE_WIFI_DEV" ]; then
                ensure_latency "$ACTIVE_ETH_DEV" "$(svc_router "$ACTIVE_ETH_SVC")" \
                               "$ACTIVE_WIFI_DEV" "$(svc_router "$ACTIVE_WIFI_SVC")"
                local _le _lw _lpick
                _le="$(_metric_val "lat_$ACTIVE_ETH_DEV")"
                _lw="$(_metric_val "lat_$ACTIVE_WIFI_DEV")"
                _lpick="$(pick_fastest "$ACTIVE_ETH_DEV" "$_le" "$ACTIVE_WIFI_DEV" "$_lw")"
                case "$_lpick" in
                    "")   want="" ;;
                    tie)  want="$cur" ;;
                    *)    want="$_lpick" ;;
                esac
                log "延时优先: eth=${_le:-?}ms wifi=${_lw:-?}ms -> ${_lpick:-保持}"
            elif [ "$eth_ok" -eq 1 ] && [ -n "$ACTIVE_ETH_DEV" ]; then
                want="$ACTIVE_ETH_DEV"
            elif [ "$wifi_ok" -eq 1 ] && [ -n "$ACTIVE_WIFI_DEV" ]; then
                want="$ACTIVE_WIFI_DEV"
            fi
            ;;
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
    # 链路与实测：解释"为什么走了这条"。
    # 注意：以前这里写"Wi-Fi 读不到链路速率"，其实不对——读不到的是
    # networksetup -getMedia（只回 autoselect），system_profiler 里有真实的
    # Transmit Rate 和噪声底。用户最初的疑问"网线 100M、Wi-Fi 标称 1000M，
    # 为什么不走 Wi-Fi"，答案就在这里。
    if [ -n "$ACTIVE_ETH_DEV" ]; then
        echo "以太网链路   : $(link_media "$ACTIVE_ETH_DEV" 2>/dev/null || echo 未知)"
    fi
    if [ -n "$ACTIVE_WIFI_DEV" ]; then
        # 一次 system_profiler 拿全四项（它一次要约 1.7 秒，分两次调白等一倍）
        local _wrssi="" _wch="" _wrate="" _wnoise=""
        _wcur="$(wifi_current_all 2>/dev/null)"
        if [ -n "$_wcur" ]; then
            set -- $_wcur
            _wrssi="$1"; _wch="$2"; _wrate="$3"; _wnoise="$4"
        fi
        if [ -n "$_wrssi" ]; then
            # 信噪比 = 信号 - 噪声。差值小于 20dB 说明信号被噪声淹了，
            # 这时协商速率再高也白搭——这才是"有信号却慢"的真正原因。
            local _snr_txt=""
            if [ -n "$_wnoise" ] && [ "$_wnoise" != "0" ]; then
                _snr_txt="  信噪比 $(( _wrssi - _wnoise )) dB"
            fi
            echo "Wi-Fi 信号    : ${_wrssi} dBm（$(wifi_bars "$_wrssi")/4 格）  信道 ${_wch:-?}  协商速率 ${_wrate:-?} Mbps  噪声 ${_wnoise:-?} dBm${_snr_txt}"
        else
            echo "Wi-Fi 信号    : 读不到（可能未连接 Wi-Fi）"
        fi
    fi
    _es="$(_metric_val "speed_$ACTIVE_ETH_DEV")"
    _ws="$(_metric_val "speed_$ACTIVE_WIFI_DEV")"
    if [ -n "$_es" ] || [ -n "$_ws" ]; then
        echo "实测吞吐     : eth=$(fmt_bps "$_es")  wifi=$(fmt_bps "$_ws")"
    fi
    _el="$(_metric_val "lat_$ACTIVE_ETH_DEV")"
    _wl="$(_metric_val "lat_$ACTIVE_WIFI_DEV")"
    if [ -n "$_el" ] || [ -n "$_wl" ]; then
        echo "实测延迟     : eth=${_el:-?} ms  wifi=${_wl:-?} ms"
    fi
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
        echo "${C_WARN}⚠️  以太网服务“${ACTIVE_ETH_SVC}”已被禁用，插网线也不会启用。${C_RST}"
    fi
}

cmd_test() {
    local verbose=0
    case "$1" in -v|--verbose) verbose=1 ;; esac
    if [ "$(id -u)" -ne 0 ]; then
        echo "提示：非 root 运行，只能按“当前默认路由”探测，建议使用 sudo smartroute test"
    fi
    find_active
    local eth_res="na" wifi_res="na" eth_detail="" wifi_detail="" _p
    if [ -n "$ACTIVE_ETH_DEV" ]; then
        _p="$(probe_dev "$ACTIVE_ETH_DEV" "$(svc_router "$ACTIVE_ETH_SVC")")"
        eth_res="$(printf '%s\n' "$_p" | sed -n 1p)"
        eth_detail="$(printf '%s\n' "$_p" | sed -n 2p)"
    fi
    if [ -n "$ACTIVE_WIFI_DEV" ]; then
        _p="$(probe_dev "$ACTIVE_WIFI_DEV" "$(svc_router "$ACTIVE_WIFI_SVC")")"
        wifi_res="$(printf '%s\n' "$_p" | sed -n 1p)"
        wifi_detail="$(printf '%s\n' "$_p" | sed -n 2p)"
    fi
    echo "以太网 (${ACTIVE_ETH_DEV:-无})   : $eth_res"
    if [ "$verbose" = "1" ] && [ -n "$eth_detail" ]; then echo "    └─ $eth_detail"; fi
    echo "Wi-Fi  (${ACTIVE_WIFI_DEV:-无})   : $wifi_res"
    if [ "$verbose" = "1" ] && [ -n "$wifi_detail" ]; then echo "    └─ $wifi_detail"; fi
    return 0
}

cmd_set() {
    local kv="$1" key val target
    if [ -z "$kv" ]; then
        echo "用法: smartroute set auto|ethernet|wifi|speed|latency"
        echo "  或: smartroute set KEY=VALUE  （KEY 见 config 命令输出）"
        exit 1
    fi
    case "$kv" in
        auto)          key="MODE"; val="auto" ;;
        ethernet|eth)  key="MODE"; val="ethernet" ;;
        wifi|wlan)     key="MODE"; val="wifi" ;;
        speed|fast)    key="MODE"; val="speed" ;;
        latency|lowdelay) key="MODE"; val="latency" ;;
        *=*)           key="${kv%%=*}"; val="${kv#*=}" ;;
        *) echo "无法识别: $kv"; exit 1 ;;
    esac

    # 校验配置项
    case " $VALID_KEYS " in
        *" $key "*) ;;
        *) echo "不支持的配置项: $key"; echo "可用: $VALID_KEYS"; exit 1 ;;
    esac
    # 用和解析时同一套校验（conf_value_ok）。以前这里是另一份手写的 case，
    # 把 WIFI_PREFERRED / SPEED_TEST_URL / SPEED_TEST_TIMEOUT / SPEED_RECHECK /
    # LATENCY_RECHECK / SPEED_SWITCH_RATIO 全并进了"只能是 0 或 1"那一组——
    # 于是 App 里保存优先列表、改测速地址必然失败，用户只能手改配置文件，
    # 反而把用户往 H1（source 用户配置）那个坑里推。两处校验必须同源。
    conf_value_ok "$key" "$val" || {
        conf_value_hint "$key"
        exit 1
    }

    # 写入目标：优先用户级配置（普通用户可写，无需 sudo）
    if [ -w "$USER_CONF" ] || [ -w "$(dirname "$USER_CONF")" ]; then
        target="$USER_CONF"
    elif [ "$(id -u)" -eq 0 ]; then
        target="$CONF"
    else
        die "无法写入 ${USER_CONF}（可能属于 root）。请在 App 里重试保存并输入管理员密码，或执行: sudo chown \$(id -u) $USER_CONF"
    fi

    if ! conf_set "$key" "$val" "$target"; then
        if [ "$target" = "$USER_CONF" ] && [ "$(stat -f '%u' "$target" 2>/dev/null)" = "0" ]; then
            die "写入 $target 失败：该文件属于 root（/Users/Shared 带 sticky 位，普通用户无法替换）。请执行: sudo chown \$(id -u) $target"
        fi
        die "写入 $target 失败"
    fi
    echo "已设置 $key=${val}（写入 ${target}）"
    echo "守护进程将在下个周期（≤20 秒）生效；可 sudo smartroute watch 立即生效"
}

# 写入配置到指定文件（内部使用）
conf_set() {   # $1=KEY $2=VALUE $3=目标文件
    local key="$1" val="$2" target="$3" cu tmp
    if [ -f "$target" ]; then
        # 路径一：同目录临时文件 + 原子替换（最稳，但 /Users/Shared 带 sticky 位时
        # 非属主 mv 会 EPERM）
        tmp="$3.tmp.$$"
        if { grep -v "^$key=" "$target" > "$tmp"; } 2>/dev/null && \
           printf '%s=%s\n' "$key" "$val" >> "$tmp" 2>/dev/null && \
           mv "$tmp" "$target" 2>/dev/null; then
            :
        else
            rm -f "$tmp" 2>/dev/null
            # 路径二：退化成原地覆写（目录不可写但文件本身可写时用）
            tmp="${TMPDIR:-/tmp}/smartroute.conf.$$"
            if grep -v "^$key=" "$target" > "$tmp" 2>/dev/null && \
               printf '%s=%s\n' "$key" "$val" >> "$tmp" 2>/dev/null && \
               cat "$tmp" > "$target" 2>/dev/null; then
                rm -f "$tmp" 2>/dev/null
            else
                rm -f "$tmp" 2>/dev/null; return 1
            fi
        fi
    else
        printf '# smartroute 用户配置（优先级高于 /etc/smartroute.conf）\n' > "$target" 2>/dev/null || return 1
        printf '%s=%s\n' "$key" "$val" >> "$target" 2>/dev/null || return 1
    fi
    # root 若写了用户级配置，把属主还给控制台用户，避免以后普通用户存不进去
    if [ "$(id -u)" -eq 0 ] && [ "$target" = "$USER_CONF" ]; then
        cu="$(stat -f '%u' /dev/console 2>/dev/null)"
        if [ -n "$cu" ] && [ "$cu" != "0" ]; then
            chown "$cu" "$target" 2>/dev/null
            chmod 644 "$target" 2>/dev/null
        fi
    fi
    return 0
}

# 内部快捷写配置（自动选择用户级/系统级）
conf_set_auto() {   # $1=KEY $2=VALUE
    # root 优先写系统级配置：用户级配置若被 root 创建会变成 root 所有，
    # 而 /Users/Shared 带 sticky 位，普通用户之后再也改不动它（App 保存会失败）。
    # 但用户级优先级更高，所以若用户级里已有同一项，必须一并更新，
    # 否则用户级里的旧值会盖掉 root 的改动（例如安全阀置 0 被用户级的 1 抵掉）。
    if [ "$(id -u)" -eq 0 ]; then
        conf_set "$1" "$2" "$CONF"
        if [ -f "$USER_CONF" ] && grep -q "^$1=" "$USER_CONF" 2>/dev/null; then
            conf_set "$1" "$2" "$USER_CONF"
        fi
    elif [ -w "$USER_CONF" ] || [ -w "$(dirname "$USER_CONF")" ]; then
        conf_set "$1" "$2" "$USER_CONF"
    else
        return 1
    fi
}

cmd_log() {
    # 两种写法都认：log 40  和  log --lines 40。
    # 以前只认第一种，于是 `log --lines 40` 会把 "--lines" 当行数传给 tail，
    # 报 "tail: illegal offset"——而人看 --lines 更自然，很容易踩到。
    local n="${1:-50}"
    case "$n" in
        --lines|-n) n="${2:-50}" ;;
        ''|*[!0-9]*) n=50 ;;     # 其它非数字一律回落默认值，别把垃圾传给 tail
    esac
    [ "$n" -ge 1 ] 2>/dev/null || n=50
    if [ -f "$LOG_FILE" ]; then
        tail -n "$n" "$LOG_FILE"
    else
        echo "暂无日志（$LOG_FILE 不存在）"
    fi
}

cmd_config() {
    # `config set KEY VALUE` 是很自然的输入，但以前这里完全忽略参数，
    # 只打印一遍当前配置——用户以为设成功了，其实什么都没改。
    # 转给 cmd_set 处理（它认 KEY=VALUE），设不了会明确报错。
    if [ "${1:-}" = "set" ] && [ -n "${2:-}" ]; then
        # 支持 config set KEY VALUE 和 config set KEY=VALUE 两种写法
        case "$2" in
            *=*) cmd_set "$2" ;;
            *)   [ -n "${3:-}" ] || { echo "用法: smartroute config set KEY VALUE" >&2; exit 1; }
                 cmd_set "$2=$3" ;;
        esac
        return $?
    fi
    if [ -n "${1:-}" ]; then
        echo "用法: smartroute config            （查看当前配置）"
        echo "  或: smartroute config set KEY VALUE"
        exit 1
    fi
    echo "当前生效配置（默认值 < $CONF < ${USER_CONF}，后者优先）"
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
            echo "    ${C_WARN}注意：默认路由由 ${cur}（VPN/拨号等其他接口）持有，smartroute 不会干预${C_RST}"
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
            # 同网段通常意味着同一个网关、同一台路由器——那"双网并发"就没有
            # 第二条 WAN 可分。这条建议是可操作的（关掉开关就行），
            # 而"改路由器网段"对大多数人做不到，所以必须补上。
            if eth_wifi_same_gateway; then
                echo "    ${C_WARN}⚠️  而且两者网关相同（$(svc_router "${ACTIVE_ETH_SVC:-}" 2>/dev/null)），是同一台路由器${C_RST}"
                echo "        → 双网并发（BALANCE=1）不会有任何带宽收益，反而会把一半连接赶到更慢的接口"
                advice+=("建议关闭双网并发：smartroute balance off（或 App 里的并发分流开关）")
                advice+=("想更快就改用「网速优先/延时优先」模式挑一个更快的接口，而不是两个都用")
            fi
        else
            echo "    网段无冲突（eth=$a.x wifi=$b.x）${C_OK}✓${C_RST}"
        fi
    else
        echo "    只有一个接口活跃，无网段冲突"
    fi
    if [ -n "$ACTIVE_ETH_SVC" ] && ! svc_enabled "$ACTIVE_ETH_SVC"; then
        echo "    ${C_WARN}⚠️  以太网服务“${ACTIVE_ETH_SVC}”被禁用，插网线也不会生效${C_RST}"
        advice+=("以太网服务被禁用：系统设置→网络 里启用“${ACTIVE_ETH_SVC}”（确认要用有线时）")
    fi
    echo "    选路模式: ${MODE}（auto=谁有外网走谁 / ethernet=强制有线 / wifi=强制无线）"

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
        local bad=0
        while read -r cidr dev extra; do
            case "$cidr" in ""|\#*) continue ;; esac
            [ -n "$dev" ] || continue
            # 和 cmd_rule add 用同一套校验。smartroute.rules 在 /Users/Shared
            # （世界可写 + sticky），任何本地用户都能写；不校验就等于让 root
            # 照着文件内容执行 route add -net <任意字符串>。
            if ! valid_cidr "$cidr" || ! valid_dev "$dev"; then
                bad=$((bad+1))
                log "分流规则: 跳过非法条目 '$cidr $dev'（CIDR 或接口不合法）"
                continue
            fi
            want="$want$cidr@$dev;"
        done < "$RULES_FILE"
        [ "$bad" -eq 0 ] || log "分流规则: 有 $bad 条非法条目已跳过（详见上面的日志）"
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

# CIDR 合法性：IPv4/前缀 1..32。
# 抽成函数是因为**写入和应用两条路都要校验**——以前只有 cmd_rule add 校验，
# 而守护进程照 smartroute.rules 应用路由时什么都不看，于是往那个文件里
# 写任意内容就能让 root 执行 route add -net <任意内容>。
valid_cidr() {   # $1=CIDR -> 0 合法
    local cidr="$1" pfx
    printf '%s' "$cidr" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$' || return 1
    pfx="${cidr#*/}"
    [ "$pfx" -ge 1 ] && [ "$pfx" -le 32 ] || return 1
    # 每段还必须落在 0..255。只查位数不够——999.1.1.1/8 能通过 [0-9]{1,3}，
    # 而 route add 对这种地址的行为是未定义的。
    printf '%s' "${cidr%/*}" | awk -F. '{
        if (NF != 4) exit 1
        for (i = 1; i <= 4; i++) {
            if ($i !~ /^[0-9]+$/) exit 1
            if ($i + 0 > 255) exit 1
        }
    }' || return 1
    return 0
}

# 接口是否真实存在
valid_dev() {   # $1=设备名 -> 0 存在
    hardware_ports | awk -F'\t' -v d="$1" '$2==d{f=1} END{exit f?0:1}'
}

cmd_rule() {
    local sub="${1:-list}"
    case "$sub" in
        add)
            local cidr="$2" dev="$3"
            [ -n "$cidr" ] && [ -n "$dev" ] || die "用法: smartroute rule add <CIDR> <接口>
例: smartroute rule add 10.0.0.0/8 en0   （公司内网段走有线）"
            valid_cidr "$cidr" || die "CIDR 格式不正确: ${cidr}（例 10.0.0.0/8，前缀 1..32）"
            valid_dev  "$dev"  || die "没有这个接口: ${dev}（用 smartroute status 查看可用接口）"
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
            [ -f "$RULES_FILE" ] || die "规则文件不存在（${RULES_FILE}）"
            grep -v "^$cidr[[:space:]]" "$RULES_FILE" > "$RULES_FILE.tmp" 2>/dev/null && mv "$RULES_FILE.tmp" "$RULES_FILE"
            echo "已删除规则: $cidr"
            echo "守护进程将在 ≤20 秒内移除对应路由；可 sudo smartroute watch 立即生效"
            ;;
        list|"")
            echo "分流规则（${RULES_FILE}）："
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
        *) die "未知子命令: ${sub}（可用 add/del/list）" ;;
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

write_pf_rules() {   # $1=设备A $2=网关A $3=设备B $4=网关B $5=额外排除网段 $6=只走的设备(fastest)
    local d1="$1" gw1="$2" d2="$3" gw2="$4" excl="${5:-}" only="${6:-}"
    local lan1 lan2 same=0 list
    lan1="$(dev_subnet "$d1")"; lan2="$(dev_subnet "$d2")"
    if [ -n "$lan1" ] && [ "$lan1" = "$lan2" ]; then same=1; fi
    # fastest 模式：只把更快的那一个网关放进 route-to，其余流量不受影响
    if [ "$only" = "$d1" ]; then d2="$d1"; gw2="$gw1"; fi
    if [ "$only" = "$d2" ]; then d1="$d2"; gw1="$gw2"; fi
    mkdir -p "$(dirname "$PF_ANCHOR_FILE")" 2>/dev/null || return 1
    # 排除清单：局域网网段 + VPN/拨号网段 + 链路本地/组播/环回
    # 用 table 而非列表字面量：macOS 的 pf 不允许对 { a b c } 这样的列表取反
    list="$lan1"
    [ "$same" = "1" ] || list="$list $lan2"
    [ -n "$excl" ] && list="$list $excl"
    list="$list 169.254.0.0/16 224.0.0.0/4 127.0.0.0/8"
    list="$(printf '%s' "$list" | tr -s ' ' | sed 's/^ //;s/ $//')"
    {
        echo "# smartroute 双网并发分流规则 —— 由 'smartroute balance on' 自动生成"
        echo "# 撤销: sudo smartroute balance off"
        if [ -n "$only" ]; then
            echo "# 策略: fastest —— 只走延迟更低的 $only"
        else
            echo "# 策略: round-robin —— 新连接在两个接口间轮询"
        fi
        echo "ext1 = \"$d1\""
        echo "gw1  = \"$gw1\""
        echo "ext2 = \"$d2\""
        echo "gw2  = \"$gw2\""
        echo "table <lan_all> { $list }"
        if [ "$same" = "1" ]; then
            echo "# 两个接口在同一网段（${lan1}），源地址天然合法，不需要 NAT"
        else
            echo "# 两个接口在不同网段，按出口接口修正源地址，否则对端网关会丢弃"
            echo "# （macOS 的 pf 不支持 match...nat-to，用经典 nat 规则；nat-anchor \"com.apple/*\" 覆盖本锚点）"
            echo "nat on \$ext1 from ! <lan_all> to any -> (\$ext1)"
            [ "$d1" = "$d2" ] || echo "nat on \$ext2 from ! <lan_all> to any -> (\$ext2)"
        fi
        # 分流规则：fastest 模式收敛成单网关（round-robin 对单网关无意义）
        if [ "$d1" = "$d2" ]; then
            echo "pass out route-to { (\$ext1 \$gw1) } inet proto { tcp udp } from any to ! <lan_all>"
        else
            echo "pass out route-to { (\$ext1 \$gw1) (\$ext2 \$gw2) } round-robin inet proto { tcp udp } from any to ! <lan_all>"
        fi
        if [ -n "$excl" ]; then
            echo "# 已排除 VPN/拨号网段: $excl"
        fi
    } > "$PF_ANCHOR_FILE" || return 1
    # 自校验语法：pfctl 加载失败只报 "syntax error" 不给原因，先在这里挡一道
    pfctl -n -f "$PF_ANCHOR_FILE" >/dev/null 2>&1 || return 1
    return 0
}

balance_off() {   # $1=quiet 时不输出（安全阀内部调用）
    local q="${1:-}"
    # 必须 root：pf 规则和锚点文件只有 root 能动。以前这里非 root 时
    # 什么都不做，却照样打印"已关闭，网络已恢复原状"——用户以为关掉了，
    # 其实规则还在生效，排查半天白费。宁可明确报错，不要假成功。
    if [ "$(id -u)" -ne 0 ]; then
        [ "$q" = "quiet" ] || echo "错误: 关闭双网并发需要 root（要清掉 pf 分流规则）: sudo smartroute balance off" >&2
        return 1
    fi
    pfctl -a "$PF_ANCHOR" -F all 2>/dev/null
    rm -f "$PF_ANCHOR_FILE" 2>/dev/null
    if pf_enabled_by_us; then
        pfctl -d 2>/dev/null && log "双网并发: 关闭由 smartroute 开启的系统 pf"
    fi
    rm -f "$PF_STATE_FILE" 2>/dev/null
    log "双网并发分流已关闭，网络恢复原状"
    # 配置也可能写不进去（root 建的 /Users/Shared/smartroute.conf 普通用户改不动）。
    # 这个返回值以前被丢掉了，于是配置没改成也报成功。
    if ! conf_set_auto BALANCE 0; then
        [ "$q" = "quiet" ] || echo "错误: pf 规则已清掉，但配置写不进去（BALANCE 仍是 1），守护进程可能会重新开启" >&2
        return 1
    fi
    [ "$q" = "quiet" ] || echo "双网并发分流已关闭，网络已恢复原状"
    return 0
}

balance_validate() {   # $1=设备A $2=IP-A $3=设备B $4=IP-B $5=只走的设备(fastest，空=轮询) -> 0 验证通过
    local d1="$1" i1="$2" d2="$3" i2="$4" only="${5:-}" i t ok=0
    local o1a o2a o1b o2b g1 g2
    # 记录测试前的出站字节数（netstat -I <dev> -b 的第 10 列是 Obytes）
    o1a="$(netstat -I "$d1" -b 2>/dev/null | sed -n '2p' | awk '{print $10}')"
    o2a="$(netstat -I "$d2" -b 2>/dev/null | sed -n '2p' | awk '{print $10}')"
    # 10 次连通性验证。必须用 TCP 目标：pf 分流规则只作用于 proto { tcp udp }，
    # 用 ping（ICMP）验证的话流量根本不经过规则，分布检查必然误判。
    # 也不能用随机公网 IP——绝大多数不提供 HTTP(S) 服务，必然 0 成功。
    for i in 1 2 3 4 5 6 7 8 9 10; do
        case $((i % 5)) in
            0) t=223.5.5.5 ;;
            1) t=119.29.29.29 ;;
            2) t=114.114.114.114 ;;
            3) t=1.1.1.1 ;;
            *) t=8.8.8.8 ;;
        esac
        if nc -z -w "$NC_TIMEOUT" "$t" 53 >/dev/null 2>&1; then ok=$((ok+1)); continue; fi
        if nc -z -w "$NC_TIMEOUT" "$t" 443 >/dev/null 2>&1; then ok=$((ok+1)); continue; fi
        if curl -s -m 4 -o /dev/null "http://$t/" 2>/dev/null; then ok=$((ok+1)); fi
    done
    # 连通性：至少 8/10。pf 规则真有问题时会全灭（0/10），
    # 8 分的门槛足以区分"规则坏了"和"网络偶发丢包"。
    if [ "$ok" -lt 8 ]; then
        log "并发分流验证失败: 连通性 $ok/10"
        echo "验证失败：10 次 TCP 测试连接只有 $ok 次成功，已自动还原" >&2
        return 1
    fi
    # 分布检查：round-robin 应把新连接分摊到两个接口，两边的出站字节都应增长；
    # fastest 模式只走一个接口，检查那个接口有流量即可（另一个不动才对）。
    o1b="$(netstat -I "$d1" -b 2>/dev/null | sed -n '2p' | awk '{print $10}')"
    o2b="$(netstat -I "$d2" -b 2>/dev/null | sed -n '2p' | awk '{print $10}')"
    if [ -n "$o1a" ] && [ -n "$o1b" ] && [ -n "$o2a" ] && [ -n "$o2b" ]; then
        g1=$((o1b - o1a)); g2=$((o2b - o2a))
        local bad_if="" bad_g=0
        if [ "$only" = "$d1" ]; then
            [ "$g1" -le 0 ] && { bad_if="$d1"; bad_g="$g1"; }
        elif [ "$only" = "$d2" ]; then
            [ "$g2" -le 0 ] && { bad_if="$d2"; bad_g="$g2"; }
        else
            if   [ "$g1" -le 0 ] && [ "$g2" -le 0 ]; then bad_if="$d1/$d2"; bad_g="0/0"
            elif [ "$g1" -le 0 ]; then bad_if="$d1"; bad_g="$g1"
            elif [ "$g2" -le 0 ]; then bad_if="$d2"; bad_g="$g2"; fi
        fi
        if [ -n "$bad_if" ]; then
            log "并发分流验证失败: 流量未走预期接口 ($bad_if +$bad_g 字节, $d1 +$g1 / $d2 +$g2)"
            echo "验证失败：流量没有走预期接口（$d1 +$g1 字节，$d2 +$g2 字节），已自动还原" >&2
            echo "提示：本机 macOS 的 pf 可能未对出站流量生效 route-to。" >&2
            return 1
        fi
        log "并发分流验证通过: 连通性 $ok/10, 出站字节 $d1 +$g1 / $d2 +$g2${only:+ (只走 $only)}"
    else
        log "并发分流验证通过: 连通性 $ok/10（未能读取接口字节计数器，跳过分布检查）"
    fi
    return 0
}

balance_on() {
    [ "$(id -u)" -eq 0 ] || die "双网并发需要 root: sudo smartroute balance on"
    command -v pfctl >/dev/null 2>&1 || die "系统缺少 pfctl"
    # 与守护进程的 watch 抢同一把锁，避免两边同时加/删探测路由互相打架
    acquire_lock_strict
    vpn_holds_default && die "检测到 VPN/拨号接口持有默认路由，暂不支持并发分流（会穿透 VPN）"
    if vpn_full_tunnel; then
        die "检测到全流量 VPN（默认路由或 0/1+128/1 由 VPN 持有），无法安全分流，请先断开 VPN"
    fi

    # 模式: balance on [round-robin|fastest] [--force]
    # --force 要先从参数里摘掉，再解析模式。否则 mode 会变成 "--force"，
    # 落到下面的 *) 直接报"用法"错误——同网关时想强行验证 pf 规则根本用不了。
    local mode="" a
    for a in "$@"; do
        case "$a" in
            --force|-f) ;;                       # 摘掉，后面单独判断
            *) [ -n "$mode" ] || mode="$a" ;;
        esac
    done
    mode="${mode:-$BALANCE_MODE}"
    case "$mode" in
        round-robin|rr|轮询) mode="round-robin" ;;
        fastest|fast|最快)   mode="fastest" ;;
        *) die "用法: smartroute balance on [round-robin|fastest] [--force]" ;;
    esac

    find_active
    [ -n "$ACTIVE_ETH_DEV" ]  || die "没有检测到活跃的以太网接口"
    [ -n "$ACTIVE_WIFI_DEV" ] || die "没有检测到活跃的 Wi-Fi 接口"
    local eth_gw wifi_gw eth_res wifi_res eth_detail wifi_detail _p
    eth_gw="$(svc_router "$ACTIVE_ETH_SVC")"; wifi_gw="$(svc_router "$ACTIVE_WIFI_SVC")"
    [ -n "$eth_gw" ]  || die "取不到以太网网关（服务: ${ACTIVE_ETH_SVC:-?}）"
    [ -n "$wifi_gw" ] || die "取不到 Wi-Fi 网关（服务: ${ACTIVE_WIFI_SVC:-?}）"

    # 【同网关】两个接口的网关相同，说明它们经同一台路由器上网——
    # 那不是"两条 WAN"，而是"一条 WAN 的两个入口"。此时轮询分流：
    #   · 不会变快：瓶颈在路由器后面的那一条上游，不在入口
    #   · 反而更慢：一半的连接被赶到更慢的那个接口（本机 100M 有线 vs Wi-Fi）
    #   · 还可能引入非对称路由的问题
    # 所以默认拒绝。确实想试（比如验证 pf 规则）可以用 --force。
    local force=0 a2
    for a2 in "$@"; do
        case "$a2" in --force|-f) force=1 ;; esac
    done
    if [ "$eth_gw" = "$wifi_gw" ] && [ "$force" != "1" ]; then   # 与 eth_wifi_same_gateway 同一判据
        cat >&2 <<MSG
两个接口的网关相同（都是 ${eth_gw}），它们经同一台路由器上网——
这不是两条 WAN，而是一条 WAN 的两个入口。此时双网并发：
  · 不会变快：瓶颈在路由器后面的上游链路，不在入口
  · 反而更慢：一半连接会被赶到更慢的那个接口
  · 可能引入非对称路由问题
真要试试（例如验证 pf 规则）请加 --force：
  sudo smartroute balance on --force
MSG
        exit 1
    fi
    if [ "$eth_gw" = "$wifi_gw" ]; then
        echo "⚠️  两个接口网关相同（${eth_gw}），分流不会有带宽收益，仅按 --force 要求开启"
    fi

    echo "正在检测两个接口的外网连通性…"
    _p="$(probe_dev "$ACTIVE_ETH_DEV" "$eth_gw")"
    eth_res="$(printf '%s\n' "$_p" | sed -n 1p)"
    eth_detail="$(printf '%s\n' "$_p" | sed -n 2p)"
    _p="$(probe_dev "$ACTIVE_WIFI_DEV" "$wifi_gw")"
    wifi_res="$(printf '%s\n' "$_p" | sed -n 1p)"
    wifi_detail="$(printf '%s\n' "$_p" | sed -n 2p)"
    if [ "$eth_res" != "ok" ] || [ "$wifi_res" != "ok" ]; then
        die "双网并发要求两个接口都有外网（当前 以太网=$eth_res${eth_detail:+：$eth_detail} Wi-Fi=$wifi_res${wifi_detail:+：$wifi_detail}）"
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

    # 两个接口走同一个网关 = 同一条上网路径，分流不会带来带宽提升（但也不会冲突）
    if [ "$eth_gw" = "$wifi_gw" ]; then
        echo "⚠️  注意：两个接口的网关相同（${eth_gw}），属于同一条上网路径，"
        echo "    并发分流不会提升带宽；只有两个接口通往不同网关/不同外网时才有叠加效果。"
    fi

    # fastest 模式：测量两边延迟，只让更快的那个出口承载新连接
    local only="" eth_lat="" wifi_lat="" winner=""
    if [ "$mode" = "fastest" ]; then
        echo "正在测量两个接口的延迟…"
        eth_lat="$(measure_latency "$ACTIVE_ETH_DEV" "$eth_gw" | tail -n 1)"
        wifi_lat="$(measure_latency "$ACTIVE_WIFI_DEV" "$wifi_gw" | tail -n 1)"
        printf "    %s: %s ms    %s: %s ms\n" "$ACTIVE_ETH_DEV" "${eth_lat:-测不到}" \
                                            "$ACTIVE_WIFI_DEV" "${wifi_lat:-测不到}"
        winner="$(pick_fastest "$ACTIVE_ETH_DEV" "$eth_lat" "$ACTIVE_WIFI_DEV" "$wifi_lat" | tail -n 1)"
        if [ -z "$winner" ]; then
            echo "⚠️  两个接口都测不到延迟，回退为 round-robin 轮询"
            mode="round-robin"
        elif [ "$winner" = "tie" ]; then
            echo "    两个接口延迟差距不足 ${FASTEST_SWITCH_RATIO}%，按轮询分摊（避免无谓切换）"
            mode="round-robin"
        else
            only="$winner"
            echo "    → 新连接将全部走 ${winner}（更快）"
        fi
    fi

    echo "生成分流规则: $ACTIVE_ETH_DEV($lan1, gw $eth_gw) <-> $ACTIVE_WIFI_DEV($lan2, gw $wifi_gw) [$mode]"
    write_pf_rules "$ACTIVE_ETH_DEV" "$eth_gw" "$ACTIVE_WIFI_DEV" "$wifi_gw" "$excl" "$only" \
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
    # 关键校验：规则"加载成功"不等于"生效"。锚点若没被主规则集引用，
    # pfctl 照样返回 0，但流量永远不会匹配。这里必须回读确认规则真的在规则集里。
    if ! pfctl -a "$PF_ANCHOR" -s rules 2>/dev/null | grep -q "route-to"; then
        balance_off quiet
        die "pf 锚点 $PF_ANCHOR 未生效（未被主规则集引用），已还原；请检查 /etc/pf.conf 是否包含 anchor \"com.apple/*\""
    fi

    echo "正在验证分流效果（10 个测试连接）…"
    if ! balance_validate "$ACTIVE_ETH_DEV" "$(dev_ipv4 "$ACTIVE_ETH_DEV")" \
                         "$ACTIVE_WIFI_DEV" "$(dev_ipv4 "$ACTIVE_WIFI_DEV")" "$only"; then
        balance_off quiet
        die "并发分流未通过验证，已自动还原（详见 sudo smartroute log）"
    fi

    conf_set_auto BALANCE 1
    conf_set_auto BALANCE_MODE "$mode"
    state_set balance_mode "$mode"
    state_set balance_winner "$only"
    log "双网并发分流已开启: $ACTIVE_ETH_DEV <-> $ACTIVE_WIFI_DEV 模式=$mode${only:+ 最快=$only}"
    echo
    if [ "$mode" = "fastest" ]; then
        echo "✅ 双网并发已开启（最快线路模式）：新连接全部走 $only"
        echo "   • 守护进程每隔约 $((FASTEST_RECHECK * 20 / 60)) 分钟重测延迟，线路变慢会自动改走另一条"
    else
        echo "✅ 双网并发已开启：新连接会在两个接口间轮询分流"
        echo "   • 多连接/多应用（浏览、下载、云同步）会分摊到两个接口"
        echo "   • 单线程下载不会翻倍（单个连接固定走一个接口）"
    fi
    echo "   • 任一口失去外网会自动关闭并发并还原（见守护进程安全阀）"
    echo "   • 撤销: sudo smartroute balance off"
    return 0
}

cmd_balance() {
    local arg="${1:-status}"
    case "$arg" in
        on|enable|start)  shift; balance_on "$@" ;;
        off|disable|stop) balance_off ;;
        status|st)        balance_status ;;
        *) die "用法: smartroute balance on [round-robin|fastest] | off | status" ;;
    esac
}

# 【最快线路模式】定期重测两边延迟，某条线路变慢就把新连接改走另一条
# （macOS 的 pf 没有加权 pool，只能靠"只放一个网关进 route-to"来实现选快）
balance_reevaluate() {
    local eth_gw wifi_gw el wl winner cur want excl
    eth_gw="$(svc_router "$ACTIVE_ETH_SVC")"; wifi_gw="$(svc_router "$ACTIVE_WIFI_SVC")"
    [ -n "$eth_gw" ] && [ -n "$wifi_gw" ] || return 0
    el="$(measure_latency "$ACTIVE_ETH_DEV" "$eth_gw" | tail -n 1)"
    wl="$(measure_latency "$ACTIVE_WIFI_DEV" "$wifi_gw" | tail -n 1)"
    winner="$(pick_fastest "$ACTIVE_ETH_DEV" "$el" "$ACTIVE_WIFI_DEV" "$wl" | tail -n 1)"
    cur="$(state_get balance_winner)"
    want=""
    case "$winner" in
        "$ACTIVE_ETH_DEV"|"$ACTIVE_WIFI_DEV") want="$winner" ;;
        *) want="" ;;          # tie 或两边都测不到 → 回退成两条轮询
    esac
    [ "$want" = "$cur" ] && return 0
    log "最快线路重测: $ACTIVE_ETH_DEV=${el:-测不到}ms / $ACTIVE_WIFI_DEV=${wl:-测不到}ms → ${want:-两条轮询}（原 ${cur:-两条轮询}）"
    excl="$(other_nets | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    write_pf_rules "$ACTIVE_ETH_DEV" "$eth_gw" "$ACTIVE_WIFI_DEV" "$wifi_gw" "$excl" "$want" || return 1
    pfctl -e 2>/dev/null
    pfctl -a "$PF_ANCHOR" -f "$PF_ANCHOR_FILE" 2>/dev/null || return 1
    state_set balance_winner "$want"
    notify "smartroute" "已切换到更快的线路: ${want:-两条轮询}"
    return 0
}

balance_status() {
    echo "=== 双网并发（pf 分流）状态  $(ts) ==="
    find_active 2>/dev/null   # 为了判断两个接口的网关是否相同
    # 同网关要一上来就醒目地说：这不是两条 WAN，分流没有带宽收益。
    # 用户很容易以为"插了网线又连着 Wi-Fi"就是双 WAN，其实同一个路由器
    # 出来的还是同一条上游链路——瓶颈不在入口。
    if eth_wifi_same_gateway; then
        local _sgw=""
        _sgw="$(svc_router "${ACTIVE_ETH_SVC:-}" 2>/dev/null)"
        echo
        echo "  ⚠️  两个接口网关相同（${_sgw:-同一路由器}），经同一台路由器上网。"
        echo "     这不是两条 WAN，而是一条 WAN 的两个入口——双网并发不会变快，"
        echo "     反而会把一半连接赶到更慢的接口。建议 BALANCE=0。"
        echo "     （确实想验证 pf 规则可 sudo smartroute balance on --force）"
        echo
    fi
    pf_enabled
    case $? in
        0) echo "  系统 pf        : 开启" ;;
        1) echo "  系统 pf        : 关闭" ;;
        *) echo "  系统 pf        : 未知（无权限读取，请用 sudo smartroute balance status）" ;;
    esac
    # 非 root 读不了 /dev/pf（Permission denied），此时无法判断是否已加载，
    # 不能显示成"未加载"——那会让人以为规则丢了
    if pfctl -a "$PF_ANCHOR" -s rules 2>&1 | grep -q "Permission denied"; then
        echo "  分流规则       : 无法读取（需 sudo smartroute balance status）"
    elif pf_anchor_loaded; then
        echo "  分流规则       : 已加载（${PF_ANCHOR_FILE}）"
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
    local bmode bwinner
    bmode="$(state_get balance_mode)"; bwinner="$(state_get balance_winner)"
    [ -n "$bmode" ] || bmode="$BALANCE_MODE"
    if [ "$bmode" = "fastest" ]; then
        echo "  分流策略       : 最快线路（只走 ${bwinner:-未定}）"
    else
        echo "  分流策略       : 轮询（两个接口交替）"
    fi
    # 实时测一次两边延迟，方便判断"哪条更快"
    if [ -n "$ACTIVE_ETH_DEV" ] || true; then :; fi
    find_active >/dev/null 2>&1
    if [ -n "$ACTIVE_ETH_DEV" ] && [ -n "$ACTIVE_WIFI_DEV" ]; then
        local eg wg el wl
        eg="$(svc_router "$ACTIVE_ETH_SVC")"; wg="$(svc_router "$ACTIVE_WIFI_SVC")"
        echo "  实时延迟       : 测量中…"
        el="$(measure_latency "$ACTIVE_ETH_DEV" "$eg" | tail -n 1)"
        wl="$(measure_latency "$ACTIVE_WIFI_DEV" "$wg" | tail -n 1)"
        printf "    %-8s %s ms   %-8s %s ms\n" "$ACTIVE_ETH_DEV" "${el:-测不到}" \
                                            "$ACTIVE_WIFI_DEV" "${wl:-测不到}"
    fi
    if [ -f "$PF_ANCHOR_FILE" ]; then
        echo "  规则内容       :"
        sed 's/^/    /' "$PF_ANCHOR_FILE" | grep -v '^    #' | sed '/^    $/d'
    fi
    echo
    if [ "$bmode" = "fastest" ]; then
        echo "  原理: 新连接固定走延迟更低的接口；守护进程定期重测，变慢会自动改走另一条"
    else
        echo "  原理: 新连接按轮询在两个网关间分流（不同连接走不同接口）"
    fi
    echo "  限制: 单线程传输不会加速；IPv6 流量不受影响；VPN 默认路由下不可用"
    return 0
}

[ "$(uname -s)" = "Darwin" ] || die "本工具仅支持 macOS"

trap 'cleanup_probe_routes >/dev/null 2>&1; rm -rf "$LOCK_DIR" 2>/dev/null' EXIT INT TERM HUP

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

# 严格版抢锁：被其他实例占用时不静默退出，而是报错（供 balance 这类交互命令用）
acquire_lock_strict() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        local pid
        pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            die "另一个 smartroute 正在运行（pid ${pid}），请等它结束再试"
        fi
        rm -rf "$LOCK_DIR" 2>/dev/null
        mkdir "$LOCK_DIR" 2>/dev/null || die "无法创建锁目录 $LOCK_DIR"
    fi
    echo $$ > "$LOCK_DIR/pid"
}

# 修复用户级配置属主：早期版本守护进程以 root 写过 /Users/Shared/smartroute.conf，
# 该目录带 sticky 位，普通用户之后无法替换它，App 的"保存"就会失败。
cmd_fixconf() {
    local f="$USER_CONF" cu
    if [ ! -e "$f" ]; then echo "用户级配置不存在（${f}），无需修复"; return 0; fi
    cu="$(stat -f '%u' "$f" 2>/dev/null)"
    echo "文件: $f  属主 uid=$cu  权限: $(stat -f '%Sp' "$f" 2>/dev/null)"
    if [ "$(id -u)" -ne 0 ]; then
        [ "$cu" = "$(id -u)" ] && { echo "属主就是当前用户，无需修复"; return 0; }
        die "需要 root 修复属主: sudo smartroute fixconf"
    fi
    local owner; owner="$(stat -f '%u' /dev/console 2>/dev/null)"
    [ -n "$owner" ] && [ "$owner" != "0" ] || owner="$(id -un)"
    chown "$owner" "$f" && chmod 644 "$f" \
        && echo "✅ 已把 $f 归还给 ${owner}，App 保存恢复正常" \
        || die "修复失败"
    return 0
}

# ---------------- 一键诊断报告 ----------------
# 输出纯文本（不带颜色码），可直接重定向到文件贴给别人看。
# 用法: smartroute report > report.txt   （root 下信息更全）
cmd_report() {
    echo "===== smartroute 诊断报告 ====="
    echo "生成时间: $(ts)"
    echo "运行身份: $(id -un) (uid=$(id -u))"
    echo "系统: $(sw_vers -productVersion 2>/dev/null) $(sw_vers -buildVersion 2>/dev/null)"
    echo "架构: $(uname -m)"

    echo
    echo "----- [1] 硬件接口 -----"
    find_active
    echo "以太网设备: ${ACTIVE_ETH_DEV:-无}   服务: ${ACTIVE_ETH_SVC:-无}"
    echo "Wi-Fi 设备: ${ACTIVE_WIFI_DEV:-无}   服务: ${ACTIVE_WIFI_SVC:-无}"
    echo "默认路由: $(default_dev)  via  $(default_gw)"

    echo
    echo "----- [2] 接口地址（含未激活的） -----"
    service_devices | while IFS=$'\t' read -r name dev; do
        [ -n "$dev" ] || continue
        local ip; ip="$(dev_ipv4 "$dev" 2>/dev/null)"
        printf '    %-8s %-22s %s\n' "$dev" "$name" "${ip:-(无 IPv4)}"
    done

    echo
    echo "----- [3] 路由表（默认 + 非常规） -----"
    # 只看 IPv4（目标列不含冒号），否则 utun/fe80 的 IPv6 行会把报告撑爆
    netstat -rn 2>/dev/null | awk 'NR==1 || ($1 !~ /:/ && $2 !~ /:/ && (/^default/ || /^169.254/ || /utun/)) {print "    " $0}'

    echo
    echo "----- [4] pf 状态 -----"
    if [ "$(id -u)" -eq 0 ]; then
        echo "pf 启用状态: $(pfctl -s info 2>/dev/null | awk '/^Status/{print $2}')"
        echo "本工具锚点 ($PF_ANCHOR) 规则:"
        local rules
        rules="$(pfctl -a "$PF_ANCHOR" -s rules 2>/dev/null)"
        if [ -n "$rules" ]; then printf '%s\n' "$rules" | sed 's/^/    /'; else echo "    (空 / 未加载)"; fi
    else
        echo "（非 root，跳过。要完整报告请用: sudo smartroute report）"
    fi
    echo "锚点文件 $PF_ANCHOR_FILE: $([ -f "$PF_ANCHOR_FILE" ] && echo 存在 || echo 不存在)"

    echo
    echo "----- [5] 配置 -----"
    echo "# $CONF"
    [ -f "$CONF" ] && sed 's/^/    /' "$CONF" || echo "    (不存在)"
    echo "# $USER_CONF"
    [ -f "$USER_CONF" ] && sed 's/^/    /' "$USER_CONF" || echo "    (不存在)"
    echo "# 静态分流规则 $RULES_FILE"
    [ -f "$RULES_FILE" ] && sed 's/^/    /' "$RULES_FILE" || echo "    (空 / 不存在)"

    echo
    echo "----- [6] 守护进程状态 -----"
    if [ "$(id -u)" -eq 0 ]; then
        launchctl print system/com.user.smartroute >/dev/null 2>&1 \
            && echo "launchd: 已加载" || echo "launchd: 未加载"
    else
        echo "（非 root，跳过 launchctl 查询）"
    fi
    echo "plist: $([ -f /Library/LaunchDaemons/com.user.smartroute.plist ] && echo 存在 || echo 不存在)"
    echo "命令行: $([ -x /usr/local/bin/smartroute ] && echo 已安装 || echo 未安装)"
    echo "脚本路径: $0"

    echo
    echo "----- [7] 状态文件 -----"
    if [ -f "$STATE_FILE" ]; then sed 's/^/    /' "$STATE_FILE"; else echo "    (不存在)"; fi

    echo
    echo "----- [8] 最近日志（最后 30 行） -----"
    if [ -f "$LOG_FILE" ]; then tail -n 30 "$LOG_FILE" | sed 's/^/    /'; else echo "    (无日志)"; fi

    echo
    echo "----- [9] 双网并发状态 -----"
    balance_status 2>/dev/null | sed 's/^/    /' || echo "    (读取失败，可能需要 root)"

    echo
    echo "----- [10] Wi-Fi 网络与故障转移 -----"
    _wsig="$(wifi_current_signal 2>/dev/null)"
    if [ -n "$_wsig" ]; then
        set -- $_wsig
        echo "当前信号: $1 dBm（$(wifi_bars "$1")/4 格）  信道 ${2:-?}"
    else
        echo "当前信号: 读不到（Wi-Fi 可能未连接）"
    fi
    echo "已保存的网络（靠前优先）:"
    wifi_saved_list 2>/dev/null | sed 's/^/    /' || echo "    (读取失败)"
    echo "自动故障转移: WIFI_FAILOVER=$WIFI_FAILOVER  优先列表=${WIFI_PREFERRED:-(空)}  冷却=${WIFI_FAILOVER_COOLDOWN}秒"
    _wfl="$(state_get wifi_failover_last 2>/dev/null)"
    case "$_wfl" in
        ''|*[!0-9]*) _wfl="从未" ;;
        *) _wfl="$(date -r "$_wfl" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$_wfl")" ;;
    esac
    echo "上次故障转移尝试: $_wfl"

    echo
    echo "===== 报告结束 ====="
    echo "提示：把这份报告贴给别人时，里面的 IP 都是内网地址（192.168.x.x 之类），"
    echo "     不包含密码或令牌，可以放心分享。"
}

# ---------------- Wi-Fi 网络选择与自动故障转移 ----------------
# 说明（重要）：
#   · macOS 不给人看"附近有哪些 Wi-Fi"的免权限接口。CoreWLAN 扫描能拿到信号强度，
#     但 SSID 要位置权限；networksetup 的 -getairportnetwork 在部分系统上也读不到。
#   · 但"已保存的网络"是免权限的（networksetup -listpreferredwirelessnetworks），
#     所以自动故障转移走这条路线：Wi-Fi 上不了网时，按优先级逐个试连已保存的网络，
#     连上后立刻探测外网，通了就留下、不通就下一个。不需要位置权限，也不需要用户输密码
#     （已保存的网络密码在钥匙串里）。
#   · networksetup -setairportnetwork 失败时**也返回退出码 0**，所以成败必须解析输出文本。

# 已保存的 Wi-Fi 列表（按系统偏好顺序，最优先在前）
wifi_saved_list() {
    networksetup -listpreferredwirelessnetworks "$ACTIVE_WIFI_DEV" 2>/dev/null \
        | sed -n '2,$p' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
}

# 候选列表 = WIFI_PREFERRED 里指定的（靠前优先）+ 其余已保存的（去重）
wifi_preferred_candidates() {
    local pref saved out="" ssid
    pref="$(printf '%s' "$WIFI_PREFERRED" | tr ',' ' ')"
    saved="$(wifi_saved_list | tr '\n' ' ')"
    for ssid in $pref $saved; do
        [ -n "$ssid" ] || continue
        case " $out " in *" $ssid "*) continue ;; esac
        out="$out $ssid"
    done
    printf '%s\n' "${out# }"
}

# ---------- 附近网络扫描（免权限） ----------
# macOS 的通用 Wi-Fi 扫描拿不到 SSID（要「定位服务」权限），但按指定 SSID
# 扫描（CoreWLAN scanForNetworks(withSSID:)）不需要权限。我们只关心
# "已保存的网络在不在范围"，正好用后者，由 tools/wifiscan.swift 实现。
#
# 输出协议（TSV）：SSID \t rssi \t channel \t fresh
#   fresh=1 表示这次真的发了探测；fresh=0 表示系统直接返回了缓存。
#   【必须区分】系统对扫描有冷却，刚扫过 A 紧接着问 B 可能拿 A 的缓存回答，
#   而缓存里只有 A——B 就被误判成"不在范围"。所以"找不到"只有配 fresh=1 才算数；
#   而"找到了"（rssi 有值）永远可信。
WIFI_SCAN_TTL="${WIFI_SCAN_TTL:-25}"     # 扫描结果缓存多久（秒）
wifi_scan_bin() {   # -> stdout: helper 路径；找不到输出空
    local d c
    # 脚本自身所在目录。不能只信 $0——被 source 进来时 $0 是调用方的路径，
    # 测试里就是因此找不到 helper 的。BASH_SOURCE[0] 才是当前文件。
    d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    for c in "$d/wifiscan" "$d/../MacOS/wifiscan" "$d/../Resources/wifiscan" \
             "/usr/local/bin/smartroute-wifiscan" \
             "/Applications/SmartRoute.app/Contents/MacOS/wifiscan" \
             "/Applications/SmartRoute.app/Contents/Resources/wifiscan"; do
        [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

# 扫一批 SSID。$1=空格分隔的 SSID 列表；$2=thorough（1=多轮重试，默认 0）。
#   thorough=1 约 10 秒，能把"未探测"压到最少；给交互式命令用。
#   thorough=0 约 1 秒；给自动切换这类不能等的场合用。
# -> stdout: "SSID rssi channel"（只含有信号的，按信号降序）
# -> 另设 WIFI_SCAN_UNKNOWN=几个没能确认在不在范围
wifi_scan() {
    local list="$1" thorough="${2:-0}" bin line ssid rssi ch fresh need="" out="" s
    local NL=$'\n' 
    bin="$(wifi_scan_bin)" || { WIFI_SCAN_AVAILABLE=0; WIFI_SCAN_UNKNOWN=0; return 1; }
    WIFI_SCAN_AVAILABLE=1
    WIFI_SCAN_UNKNOWN=0
    [ -n "$list" ] || return 1

    # 缓存还新鲜的直接拿来用
    for s in $list; do
        [ -n "$s" ] || continue
        if _metric_fresh "wifiscan_$s" "$WIFI_SCAN_TTL"; then
            line="$(_metric_get "wifiscan_$s")"
            rssi="${line%% *}"
            [ "$rssi" != "-" ] && out="$out$s $line$NL"
        else
            need="$need $s"
        fi
    done

    # 剩下的真扫。helper 输出 TSV：SSID \t rssi \t channel \t fresh
    if [ -n "${need# }" ]; then
        local extra=""
        [ "$thorough" = "1" ] || extra="--quick"
        while IFS="$(printf '\t')" read -r ssid rssi ch fresh; do
            [ -n "$ssid" ] || continue
            if [ "$rssi" != "-" ]; then
                # 找到了永远可信，直接缓存
                _metric_set "wifiscan_$ssid" "$rssi $ch $fresh"
                out="$out$ssid $rssi $ch$NL"
            elif [ "$fresh" = "1" ]; then
                # 真扫过且确实没有——权威的"不在范围"，可以缓存
                _metric_set "wifiscan_$ssid" "- $ch $fresh"
            else
                # 没找到、又没真扫：这是系统缓存的假阴性，**不能缓存也不能信**。
                # 实测：先问 A（真扫 1.3s），紧接着问 B 只用 0.02s 且报空，
                # 但单独问 B 能拿到 -60。系统约每 5 秒才肯真扫一次。
                WIFI_SCAN_UNKNOWN=$((WIFI_SCAN_UNKNOWN+1))
            fi
        done < <("$bin" $extra $need 2>/dev/null)
    fi

    [ -n "$out" ] || return 1
    # 按信号降序。两个要点：
    #  · -s 稳定排序：相等的键必须保持输入顺序，否则"其余按原顺序垫后"作废
    #  · 先按 SSID 去重取最强：helper 已经这么做了，这里防一手重复行
    #  · out 是"一行一条"，别用 printf '%s\n' ${out}（会把所有条拼成一行）
    printf '%s' "$out" | awk 'NF>=3 {
            r=($2=="-"?-999:$2+0)
            if (!($1 in best) || r+0 > best[$1]) { best[$1]=r+0; ch[$1]=$3 }
        }
        END { for (k in best) printf "%d\t%s\t%s\n", best[k], k, ch[k] }' \
        | sort -s -t"$(printf '\t')" -k1,1nr | awk -F"$(printf '\t')" '{print $2" "$1" "$3}'
}

# 附近有信号的已保存网络（按信号排序）。-> stdout: "SSID rssi channel"
wifi_nearby() { wifi_scan "$(wifi_saved_list | tr '\n' ' ')" "${1:-0}"; }

# 一次 system_profiler 拿全：信号、信道、协商速率、噪声底。
# -> stdout: "<rssi> <channel> <rate> <noise>"，读不到输出空
#
# 为什么要合并成一次：system_profiler SPAirPortDataType 一次要约 1.7 秒，
# 而"信号"和"速率"原本是两个函数各调一次，status 里白等一倍（2.2s）。
# 也不能用"进程内变量缓存"偷懒——调用方都是 $(...) 子 shell，
# 子 shell 里的赋值传不回父 shell，缓存永远命中不了。
wifi_current_all() {
    local out rssi ch rate noise bin fast=0
    # 快路径：CoreWLAN helper。system_profiler 一次要约 1.6 秒，而 App 每 5 秒
    # 轮询一次、status 也要用；helper 首次约 0.3 秒、之后命中缓存只要 0.01 秒。
    # helper 不在（没装/没构建）、或输出不合格，就回退 system_profiler——
    # 功能不变，只是慢。
    #
    # 注意这里用 fast 标志而不是直接 return：校验不过时必须"继续往下走"去
    # 用 system_profiler，而不是 return 1。曾经写成 return 1，结果 Wi-Fi
    # 没连上时（rssi=0）整个函数直接返回失败，连兜底都不走了。
    bin="$(wifi_scan_bin)"
    if [ -n "$bin" ]; then
        out="$("$bin" --current 2>/dev/null)"
        if [ -n "$out" ]; then
            # helper 输出 TSV：rssi \t channel \t rate \t noise
            IFS="$(printf '\t')" read -r rssi ch rate noise <<EOF2
$out
EOF2
            # 校验：必须是数字，否则当没读到，回退 system_profiler。
            # 不校验的话 helper 一旦输出异常（格式变动、partial write），
            # 用户就会看到"信号 abc dBm（?/4 格）"这种垃圾，还以为程序坏了。
            case "$rssi" in ''|*[!0-9-]*) rssi="" ;; esac
            case "$ch"   in ''|*[!0-9-]*) ch="" ;; esac
            case "$rate" in ''|*[!0-9-]*) rate="" ;; esac
            case "$noise" in ''|*[!0-9-]*) noise="" ;; esac
            # rssi=0 对 Wi-Fi 不可能，通常是没连上——同样回退
            [ -n "$rssi" ] && [ "$rssi" != "0" ] && fast=1
            if [ "$fast" = "1" ]; then
                printf '%s %s %s %s\n' "$rssi" "${ch:-0}" "${rate:-0}" "${noise:-0}"
                return 0
            fi
        fi
    fi
    out="$(system_profiler SPAirPortDataType 2>/dev/null)"
    [ -n "$out" ] || return 1
    rssi="$(printf '%s\n' "$out" | sed -n 's/.*Signal \/ Noise:[[:space:]]*\(-*[0-9][0-9]*\) dBm.*/\1/p' | head -1)"
    [ -n "$rssi" ] || return 1
    ch="$(printf '%s\n' "$out" | sed -n 's/.*Channel:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
    rate="$(printf '%s\n' "$out" | sed -n 's/.*Transmit Rate:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
    noise="$(printf '%s\n' "$out" | sed -n 's/.*Signal \/ Noise:[[:space:]]*-*[0-9]* dBm \/ *\(-*[0-9][0-9]*\) dBm.*/\1/p' | head -1)"
    printf '%s %s %s %s\n' "$rssi" "${ch:-0}" "${rate:-0}" "${noise:-0}"
}

# 当前连接的信号强度（dBm）与信道。这两个免权限，system_profiler 就能读到。
wifi_current_signal() {   # ->  stdout: "<rssi> <channel>"，读不到输出空
    local a
    a="$(wifi_current_all)" || return 1
    set -- $a
    printf '%s %s\n' "$1" "$2"
}

# 当前 Wi-Fi 的真实协商速率（Mbps）与噪声底（dBm）。
# 这两个免权限，system_profiler 就能读到——所以别再说什么"macOS 读不到
# Wi-Fi 链路速率"了，读不到的是 networksetup -getMedia（只回 autoselect）。
# 用户最初的疑问"网线 100M、Wi-Fi 标称 1000M，为什么不走 Wi-Fi"，
# 这里给出的是真实答案（本机实测 864 Mbps，但信号只有 2 格）。
wifi_current_rate() {   # -> stdout: "<速率Mbps> <噪声dBm>"，读不到输出空
    local a
    a="$(wifi_current_all)" || return 1
    set -- $a
    printf '%s %s\n' "$3" "$4"
}

# dBm -> 人类可读的格数（0~4）。-50 以内满格，-80 以外一格
wifi_bars() {   # $1=dBm
    local r="$1"
    case "$r" in
        ''|*[!0-9-]*) echo "?" ;;
        -5*|-4*) echo "4" ;;
        -6*) echo "3" ;;
        -7*) echo "2" ;;
        *) echo "1" ;;
    esac
}

# 连接到一个 Wi-Fi。$1=SSID。成功返回 0。
# 注意：networksetup 失败也返回 0，所以必须看输出里有没有错误字样。
wifi_join() {   # $1=SSID -> 0 成功 / 1 失败
    local ssid="$1" out
    [ -n "$ssid" ] || return 1
    out="$(networksetup -setairportnetwork "$ACTIVE_WIFI_DEV" "$ssid" 2>&1)"
    WIFI_JOIN_REASON=""
    case "$out" in
        *"Could not find network"*)
            # 旁边没这个路由器—— saved 列表里绝大多数都是这种情况，属正常
            WIFI_JOIN_REASON="outofrange"
            log "wifi join '$ssid': 不在范围"
            return 1 ;;
        *"Failed"*|*"Error"*|*"error"*|*"not associated"*|*"Invalid"*)
            WIFI_JOIN_REASON="joinfailed"
            log "wifi join '$ssid' 失败: $out"
            return 1 ;;
        *) return 0 ;;
    esac
}

# 上一次 wifi_join 的失败类别：outofrange=不在范围 / joinfailed=找到了但连不上
wifi_join_reason() { printf '%s' "${WIFI_JOIN_REASON:-joinfailed}"; }

# 连上之后等接口真正拿到地址（DHCP 可能要一两秒）
wifi_wait_associated() {   # $1=最多等几秒
    local i max=$(( ${1:-6} * 2 ))
    i=0
    while [ "$i" -lt "$max" ]; do
        dev_active "$ACTIVE_WIFI_DEV" && return 0
        sleep 0.5
        i=$((i+1))
    done
    dev_active "$ACTIVE_WIFI_DEV"
}

# 试连列表里的 Wi-Fi，返回第一个"能上网"的 SSID（stdout）。
# $1=候选列表（空格分隔，可为空=用已保存列表）；$2=每个最多等几秒
# 副作用：会真的切换网络。调用方负责确认"现在确实上不了网"。
# 当前 Wi-Fi 是否已经能上网（不切任何网络，只探测）
wifi_current_ok() {
    [ -n "$ACTIVE_WIFI_DEV" ] || return 1
    dev_active "$ACTIVE_WIFI_DEV" || return 1
    probe_dev "$ACTIVE_WIFI_DEV" "$(svc_router "$ACTIVE_WIFI_SVC")" | sed -n 1p | grep -q '^ok$'
}

# 把 Wi-Fi 断电重连一次。macOS 会因此自动重新加入它记住的网络——
# 这是"当前 SSID 读不到"（要位置权限）时唯一的还原手段。
wifi_power_cycle() {   # $1=设备
    local d="$1"
    [ -n "$d" ] || return 1
    log "循环 Wi-Fi 电源以恢复原网络 ($d)"
    set_wifi_power "$d" off
    sleep 2
    set_wifi_power "$d" on
    wifi_wait_associated 10
}

# 把候选列表按"附近信号强弱"重排：确认有信号的在前（强的更前），
# 其余保持原顺序垫后。注意"没能确认"和"确认不在范围"都不提前——
# 前者可能是假阴性，排在前面只是多花几秒，漏掉能用的网络才是真错。
wifi_rank_candidates() {   # $1=空格分隔候选 -> stdout: 重排后的候选
    local cands="$1" near="" s out=""
    local NL=$'\n' 
    near="$(wifi_scan "$cands" 0)"
    [ -n "$near" ] || { printf '%s\n' "$cands"; return 0; }

    # near 是 "SSID rssi ch" 一行一条；没有信号的候选原样保留在后面
    local have=""
    have="$(printf '%s\n' "$near" | awk '{print $1}' | tr '\n' ' ')"
    for s in $cands; do
        case " $have " in *" $s "*) ;; *) near="$near$NL$s - 0" ;; esac
    done

    printf '%s\n' "$near" | awk 'NF>=3 {r=($2=="-"?-999:$2+0); print r"\t"$1}' \
        | sort -s -t"$(printf '\t')" -k1,1nr | awk -F"$(printf '\t')" '{printf "%s ", $2}'
    echo
}

wifi_try_candidates() {   # $1=候选列表 $2=每个等几秒 -> stdout: 成功的 SSID；另设 WIFI_TRY_* 汇总
    local cands="$1" wait_s="${2:-6}" ssid gw
    WIFI_TRY_TOTAL=0; WIFI_TRY_OUTOFRANGE=0; WIFI_TRY_NOINET=0; WIFI_TRY_JOINFAIL=0
    [ -n "$cands" ] || cands="$(wifi_saved_list | tr '\n' ' ')"
    [ -n "$cands" ] || return 1

    # 【安全】当前网络已经能上网就什么都别做。
    # 用户碰到的真实 case：当前 Wi-Fi 有网，tryall 却把当前网络重新 join 了一遍，
    # 结果 "Failed to join network" —— 等于自己把一条好线路踢掉了。
    # 当前 SSID 读不到（要位置权限），所以没法"跳过当前网络"，
    # 但"已经能上网就不动手"不需要知道 SSID，而且更彻底。
    if wifi_current_ok; then
        log "wifi tryall: 当前 Wi-Fi 已能上网，不切换"
        WIFI_TRY_ALREADY_OK=1
        return 1
    fi
    WIFI_TRY_ALREADY_OK=0

    # 记住动手前是否关联着：全失败时如果是被我们踢下来的，要负责还原
    local was_assoc=0
    dev_active "$ACTIVE_WIFI_DEV" && was_assoc=1

    for ssid in $cands; do
        [ -n "$ssid" ] || continue
        WIFI_TRY_TOTAL=$((WIFI_TRY_TOTAL+1))
        log "wifi 故障转移：试连 '$ssid'"
        if ! wifi_join "$ssid"; then
            # 区分"不在范围"和"连不上"：前者是正常的（旁边没这个路由器），
            # 后者才值得用户关注（密码改了？）。原来混在一起报"没有外网"，没法判断。
            case "$(wifi_join_reason)" in
                outofrange) WIFI_TRY_OUTOFRANGE=$((WIFI_TRY_OUTOFRANGE+1)) ;;
                *)          WIFI_TRY_JOINFAIL=$((WIFI_TRY_JOINFAIL+1)) ;;
            esac
            continue
        fi
        wifi_wait_associated "$wait_s" || { log "'$ssid' 连上了但没拿到 IP，跳过"; WIFI_TRY_NOINET=$((WIFI_TRY_NOINET+1)); continue; }
        # 连上≠能上网：门户认证/假连接很常见，必须真探一次
        gw="$(svc_router "$ACTIVE_WIFI_SVC")"
        if probe_dev "$ACTIVE_WIFI_DEV" "$gw" | sed -n 1p | grep -q '^ok$'; then
            log "wifi 故障转移：'$ssid' 可以上网"
            printf '%s\n' "$ssid"
            return 0
        fi
        log "'$ssid' 能连上但没有外网，试下一个"
        WIFI_TRY_NOINET=$((WIFI_TRY_NOINET+1))
    done

    # 全失败。如果动手前是关联着的、现在被我们踢断了，循环电源让 macOS 自动重连回去
    if [ "$was_assoc" = "1" ] && ! dev_active "$ACTIVE_WIFI_DEV"; then
        log "wifi tryall 全失败，且原网络被断开，尝试恢复"
        wifi_power_cycle "$ACTIVE_WIFI_DEV"
    fi
    return 1
}

# Wi-Fi 自动故障转移。
# 触发条件（全部满足才动，宁可不动也不能把用户正在用的网络弄坏）：
#   · WIFI_FAILOVER=1 且以 root 运行（即守护进程）
#   · 用户没有强制 MODE=ethernet
#   · Wi-Fi 确认上不了网（滞回后 wifi_ok != 1），且不是"接口都没激活"
#   · 以太网也没有外网（否则默认路由走以太网，切 Wi-Fi 没有意义）
#   · 距上次尝试已过 WIFI_FAILOVER_COOLDOWN 秒
wifi_failover_if_needed() {   # $1=wifi_ok $2=eth_ok $3=wifi_res
    local wifi_ok="$1" eth_ok="$2" wifi_res="$3"
    [ "$WIFI_FAILOVER" = "1" ] || return 0
    [ "$(id -u)" -eq 0 ] || return 0
    [ -n "$ACTIVE_WIFI_DEV" ] || return 0
    [ "$MODE" = "ethernet" ] && return 0
    [ "$wifi_ok" != "1" ] || return 0
    [ "$eth_ok" != "1" ] || return 0
    # 接口压根没激活（Wi-Fi 被关/没网卡）时不要瞎试
    [ "$wifi_res" != "na" ] || return 0

    local now last
    now="$(date +%s)"
    last="$(state_get wifi_failover_last)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $((now - last)) -ge "$WIFI_FAILOVER_COOLDOWN" ] || return 0
    state_set wifi_failover_last "$now"

    log "Wi-Fi 故障转移：当前 Wi-Fi 上不了网，开始按优先级试连其它已保存网络"
    local got
    got="$(wifi_try_candidates "$(wifi_preferred_candidates)" 6)"
    if [ -n "$got" ]; then
        log "Wi-Fi 故障转移成功：已切到 $got"
        notify "smartroute" "已自动切换到可用 Wi-Fi：$got"
    else
        log "Wi-Fi 故障转移：已保存的 Wi-Fi 都没有外网，放弃本轮"
    fi
    return 0
}

# 把缓存的实测结果打成 App 好解析的 key=value
cmd_measurements() {
    find_active
    local es ws el wl
    es="$(_metric_val "speed_$ACTIVE_ETH_DEV")"
    ws="$(_metric_val "speed_$ACTIVE_WIFI_DEV")"
    el="$(_metric_val "lat_$ACTIVE_ETH_DEV")"
    wl="$(_metric_val "lat_$ACTIVE_WIFI_DEV")"
    # 没测过要给个明确的值，别留空——App 那边空值会显示成一片空白，
    # 用户分不清"没测"和"测出来是 0"
    printf 'speed:eth=%s\n'  "$([ -n "$es" ] && fmt_bps "$es" || echo 未测)"
    printf 'speed:wifi=%s\n' "$([ -n "$ws" ] && fmt_bps "$ws" || echo 未测)"
    printf 'latency:eth=%s\n'  "$([ -n "$el" ] && echo "$el ms" || echo 未测)"
    printf 'latency:wifi=%s\n' "$([ -n "$wl" ] && echo "$wl ms" || echo 未测)"
}

cmd_measure() {
    local arg="${1:-show}"
    case "$arg" in
        now|refresh)
            find_active
            [ "$(id -u)" -eq 0 ] || die "测速需要 root（要加静态路由才能分别测两个接口）"
            echo "正在测量，请稍候（两边串行测，各最多 ${SPEED_TEST_TIMEOUT} 秒）…"
            # 先作废缓存，否则 ensure_* 看到"还新鲜"就跳过了
            state_set "speed_$ACTIVE_ETH_DEV" "0"
            state_set "speed_$ACTIVE_WIFI_DEV" "0"
            state_set "lat_$ACTIVE_ETH_DEV" "0"
            state_set "lat_$ACTIVE_WIFI_DEV" "0"
            if [ -n "$ACTIVE_ETH_DEV" ] && [ -n "$ACTIVE_WIFI_DEV" ] \
               && [ "$(state_get eth_ok)" = "1" ] && [ "$(state_get wifi_ok)" = "1" ]; then
                ensure_throughput "$ACTIVE_ETH_DEV" "$ACTIVE_WIFI_DEV"
                ensure_latency "$ACTIVE_ETH_DEV" "$(svc_router "$ACTIVE_ETH_SVC")" \
                               "$ACTIVE_WIFI_DEV" "$(svc_router "$ACTIVE_WIFI_SVC")"
            fi
            cmd_measurements
            ;;
        show|st) cmd_measurements ;;
        *) die "用法: smartroute measure now|show" ;;
    esac
}

cmd_wifi() {
    local arg="${1:-status}"
    case "$arg" in
        list|ls)
            shift
            find_active
            # --raw 给 App 用：一行一个 SSID，不带序号。
            # 带序号的格式（"  1. CZ-305"）人看着舒服，但机器解析有歧义——
            # SSID 本身完全可以叫 "1. CZ-305"，那样按 "数字. " 去剥前缀就会剥错。
            # 所以人看的格式和机器读的格式分开，别让 App 去猜。
            if [ "${1:-}" = "--raw" ] || [ "${1:-}" = "-r" ]; then
                wifi_saved_list
                return 0
            fi
            echo "已保存的 Wi-Fi（靠前优先）："
            local n=0 ssid
            while IFS= read -r ssid; do
                [ -n "$ssid" ] || continue
                n=$((n+1)); printf '  %d. %s\n' "$n" "$ssid"
            done < <(wifi_saved_list)
            [ "$n" -gt 0 ] || echo "  （没有已保存的 Wi-Fi）"
            ;;
        scan|sc|nearby)
            find_active
            [ -n "$ACTIVE_WIFI_DEV" ] || die "没有检测到 Wi-Fi 接口"
            if ! wifi_scan_bin >/dev/null; then
                echo "（找不到扫描组件 wifiscan，跳过附近网络检测）"
                return 0
            fi
            # 默认 thorough（约 10 秒），把"没能确认"的压到最少；
            # --quick 约 1 秒，给 App 轮询这种不能等的场合用。
            # 注意 cmd_wifi 没有全局 shift，这里 $1 还是 "scan"，要先 shift 一次。
            shift
            local _thorough=1
            case "${1:-}" in
                --quick|-q) _thorough=0; echo "快速扫描（约 1 秒，部分结果可能未确认）…" ;;
                *) echo "正在扫描附近的 Wi-Fi（约需 10 秒）…" ;;
            esac
            local near all far="" s rssi ch
            near="$(wifi_nearby "$_thorough")"
            all="$(wifi_saved_list | tr '\n' ' ')"

            if [ -n "$near" ]; then
                echo
                echo "在范围的已保存网络（按信号排序，越靠前越好）："
                while read -r s rssi ch; do
                    [ -n "$s" ] || continue
                    printf '  %-16s %5s dBm（%s/4 格）  信道 %s\n' \
                        "$s" "$rssi" "$(wifi_bars "$rssi")" "${ch:-?}"
                done < <(printf '%s\n' "$near")
            else
                echo
                echo "附近没有已保存的网络在范围。"
            fi

            # 区分"确认不在范围"和"没能确认"——后者别让人以为查过了
            local have=""
            have="$(printf '%s\n' "$near" | awk '{print $1}' | tr '\n' ' ')"
            for s in $all; do
                case " $have " in *" $s "*) ;; *) far="$far $s" ;; esac
            done
            if [ -n "${far# }" ]; then
                echo
                echo "确认不在范围的（旁边没有这些路由器，属正常）："
                for s in $far; do printf '  %s\n' "$s"; done
            fi
            if [ "${WIFI_SCAN_UNKNOWN:-0}" -gt 0 ]; then
                echo
                echo "有 $WIFI_SCAN_UNKNOWN 个没能确认（系统扫描有冷却，不是故障），重试即可。"
            fi
            ;;
        current|cur|status|st)
            find_active
            # cmd_wifi 没有全局 shift，这里 $1 还是 "current"
            shift
            # 先把标志取下来。必须在 set -- 之前——set -- 会把位置参数
            # 换成 wifi_current_all 的输出，标志就被冲掉了。
            local _raw=0
            if [ "${1:-}" = "--raw" ] || [ "${1:-}" = "-r" ]; then _raw=1; fi
            local all
            if all="$(wifi_current_all)"; then
                set -- $all
                # --raw 给 App 用：一次调用拿全（信号/信道/速率/噪声）。
                # system_profiler 一次要约 1.7 秒，App 原来为了拿速率和噪声
                # 去跑两次 status（各 1.8 秒），Wi-Fi 页刷新要 5 秒——就是这里慢的。
                if [ "$_raw" = "1" ]; then
                    printf 'rssi=%s channel=%s rate=%s noise=%s\n' "$1" "$2" "$3" "$4"
                    return 0
                fi
                # 信噪比：差值小于 20dB 说明信号被噪声淹了，速率再高也白搭
                local _snr=""
                if [ "$4" != "0" ]; then _snr="  信噪比 $(( $1 - $4 )) dB"; fi
                printf 'Wi-Fi %s  信号 %s dBm（%s/4 格）  信道 %s' \
                    "${ACTIVE_WIFI_DEV:-?}" "$1" "$(wifi_bars "$1")" "${2:-?}"
                [ "$3" != "0" ] && printf '  协商速率 %s Mbps' "$3"
                [ "$4" != "0" ] && printf '  噪声 %s dBm' "$4"
                printf '%s\n' "$_snr"
            else
                echo "读不到当前 Wi-Fi 信号（可能未连接）"
            fi
            ;;
        join|connect)
            shift
            local target="${1:-}"
            [ -n "$target" ] || die "用法: smartroute wifi join <网络名>"
            find_active
            [ -n "$ACTIVE_WIFI_DEV" ] || die "没有检测到 Wi-Fi 接口"
            # Wi-Fi 被关了就帮你打开
            [ "$(wifi_power "$ACTIVE_WIFI_DEV")" = "off" ] && set_wifi_power "$ACTIVE_WIFI_DEV" on
            if wifi_join "$target" && wifi_wait_associated 8; then
                echo "✅ 已连接到 $target"
                [ "$NOTIFY" = "1" ] && notify "SmartRoute" "已连接到 Wi-Fi：$target"
            else
                die "连接 $target 失败（不在范围 / 密码已改 / 未保存过这个网络）"
            fi
            ;;
        tryall|scan-join)
            find_active
            [ -n "$ACTIVE_WIFI_DEV" ] || die "没有检测到 Wi-Fi 接口"
            [ "$(wifi_power "$ACTIVE_WIFI_DEV")" = "off" ] && set_wifi_power "$ACTIVE_WIFI_DEV" on

            # 已经能上网就直接说，别折腾。这是最重要的安全护栏：
            # 当前 SSID 读不到（要位置权限），没法"跳过当前网络"，
            # 但"已经能上网就不动手"不需要知道 SSID，而且更彻底。
            # 用户碰到的真实 case：当前 Wi-Fi 有网，tryall 却把当前网络重新 join
            # 了一遍，结果 Failed to join network —— 自己把好线路踢掉了。
            if wifi_current_ok; then
                echo "✅ 当前 Wi-Fi 已经可以上网，不需要切换。"
                _sig="$(wifi_current_signal 2>/dev/null)"
                if [ -n "$_sig" ]; then
                    set -- $_sig
                    echo "   信号 $1 dBm（$(wifi_bars "$1")/4 格）  信道 ${2:-?}"
                fi
                return 0
            fi

            echo "当前 Wi-Fi 上不了网，正在逐个试连已保存的网络…"
            # 用扫描结果把候选排个序：附近有信号的按信号强弱优先，
            # 够不着的排最后。排序错了只是多花几秒，不会漏掉能用的网络——
            # 所以够不着的一样会试，只是最后试。
            local got ordered
            ordered="$(wifi_rank_candidates "$(wifi_saved_list | tr '\n' ' ')")"
            got="$(wifi_try_candidates "$ordered" 6)"
            # 有几个网络没能确认在不在范围——如实告诉用户，别让他以为全查过了
            if [ "${WIFI_SCAN_UNKNOWN:-0}" -gt 0 ]; then
                echo "（有 $WIFI_SCAN_UNKNOWN 个网络没能确认在不在范围，已一并试过）"
            fi
            if [ -n "$got" ]; then
                echo "✅ 找到可用的网络：$got"
                [ "$NOTIFY" = "1" ] && notify "SmartRoute" "已切换到可用 Wi-Fi：$got"
                return 0
            fi

            # 失败要把原因说清楚。原来一律报"都没有外网"，
            # 但绝大多数是"不在范围"（旁边没这个路由器），那是正常的；
            # 真正值得用户处理的是"找到了却连不上"。
            echo "❌ 没找到能上网的网络。试了 $WIFI_TRY_TOTAL 个："
            [ "$WIFI_TRY_OUTOFRANGE" -gt 0 ] && echo "   · $WIFI_TRY_OUTOFRANGE 个不在范围（旁边没有这个路由器，属正常）"
            [ "$WIFI_TRY_JOINFAIL" -gt 0 ] && echo "   · $WIFI_TRY_JOINFAIL 个找到了但连不上（密码可能改过了）"
            [ "$WIFI_TRY_NOINET"   -gt 0 ] && echo "   · $WIFI_TRY_NOINET 个能连上但没有外网（可能要网页认证）"
            if [ "$WIFI_TRY_JOINFAIL" -gt 0 ]; then
                echo
                echo "提示：连不上的那些网络，请在系统菜单栏的 Wi-Fi 里重新输一次密码，"
                echo "     之后这里就能一键切换了。"
            fi
            if dev_active "$ACTIVE_WIFI_DEV"; then
                echo "已保留当前连接。"
            else
                echo "原网络已断开，已尝试循环 Wi-Fi 电源让系统自动重连。"
            fi
            ;;
        auto)
            shift
            case "${1:-status}" in
                # conf_set_auto 的返回值必须看：配置文件属 root 时普通用户写不进去，
                # 以前这里直接忽略，于是打印"已开启"但配置一个字都没改——
                # 用户以为设好了，守护进程却完全不按这个来。
                on|1)
                    if conf_set_auto WIFI_FAILOVER 1; then
                        echo "已开启 Wi-Fi 自动故障转移"
                    else
                        echo "错误: 写不进配置（/Users/Shared/smartroute.conf 属 root）" >&2
                        echo "     普通用户改不动它。请用 App 里的开关（会自动提权），" >&2
                        echo "     或 sudo chown \$USER /Users/Shared/smartroute.conf 后重试。" >&2
                        return 1
                    fi ;;
                off|0)
                    if conf_set_auto WIFI_FAILOVER 0; then
                        echo "已关闭 Wi-Fi 自动故障转移"
                    else
                        echo "错误: 写不进配置（/Users/Shared/smartroute.conf 属 root）" >&2
                        echo "     普通用户改不动它。请用 App 里的开关（会自动提权），" >&2
                        echo "     或 sudo chown \$USER /Users/Shared/smartroute.conf 后重试。" >&2
                        return 1
                    fi ;;
                status|st)
                    echo "WIFI_FAILOVER=$WIFI_FAILOVER"
                    echo "优先列表: ${WIFI_PREFERRED:-(空，按系统保存顺序)}"
                    echo "切换冷却: ${WIFI_FAILOVER_COOLDOWN} 秒" ;;
                *) die "用法: smartroute wifi auto on|off|status" ;;
            esac
            ;;
        *) die "用法: smartroute wifi list|current|join <网络名>|tryall|auto on|off|status" ;;
    esac
}

# ---------------- 网速优先 / 延时优先 ----------------
# 背景：MODE=auto 只看"哪个能上网"，有线永远赢。但链路质量可以差很多——
# 本例：网线协商到 100baseTX（100M），Wi-Fi 标称 1000M 但信号只有 2 格。
# 只看链路标称值没用（Wi-Fi 在 macOS 上根本读不到协商速率，networksetup -getMedia
# 对 en1 只回 autoselect），所以"网速优先"必须实测下载吞吐。
#
# 实测的两个约束：
#   1) 费流量、耗时数秒 → 结果缓存，SPEED_RECHECK 秒才重测
#   2) 两个接口不能并行测 → 会互相抢带宽，两个数都偏小，必须串行

# 实测下载吞吐。$1=设备 $2=超时秒 -> stdout: 字节/秒；失败输出空
measure_throughput() {
    local dev="$1" tmo="${2:-$SPEED_TEST_TIMEOUT}" out
    [ -n "$dev" ] || return 1
    dev_active "$dev" || return 1
    command -v curl >/dev/null 2>&1 || return 1
    # --interface 强制从这个网卡出去，否则测到的是默认路由那条
    out="$(curl --interface "$dev" -o /dev/null -s -w '%{speed_download}' \
           --max-time "$tmo" "$SPEED_TEST_URL" 2>/dev/null)"
    case "$out" in
        ''|*[!0-9.]*) return 1 ;;
    esac
    # curl 连不上时也会输出 0，那不是"测出来是 0"而是没测到
    awk -v v="$out" 'BEGIN{ exit !(v+0 > 0) }' || return 1
    printf '%s' "$out"
}

# 字节/秒 -> "12.3 Mbps"
fmt_bps() {   # $1=字节/秒
    awk -v b="${1:-0}" 'BEGIN{
        if (b <= 0) { print "未知"; exit }
        m = b * 8 / 1000000
        if (m >= 100) printf "%.0f Mbps", m
        else printf "%.1f Mbps", m
    }'
}

# 读链路协商速率（仅以太网有意义）。$1=设备 -> stdout: "100baseTX" 之类；读不到输出空
link_media() {   # $1=设备
    [ -n "$1" ] || return 1
    networksetup -getMedia "$1" 2>/dev/null | sed -n 's/^Active:[[:space:]]*//p' | head -1
}

# 缓存 helpers：state 里存 "设备:值:时间戳"
_metric_get() {   # $1=state 键 -> stdout: "值 时间戳"
    state_get "$1" 2>/dev/null
}
_metric_set() {   # $1=state 键 $2=值
    state_set "$1" "$2 $(date +%s)"
}
_metric_fresh() {   # $1=state 键 $2=有效期秒 -> 0 新鲜 / 1 过期
    local v ts
    v="$(_metric_get "$1")"
    ts="${v##* }"
    case "$ts" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ $(( $(date +%s) - ts )) -lt "$2" ]
}

# 确保两个接口的吞吐都测过（缓存新鲜就不重测）。
# 串行测：并行会互相抢带宽，两个数都失真。
ensure_throughput() {   # $1=eth_dev $2=wifi_dev
    local d
    for d in "$1" "$2"; do
        [ -n "$d" ] || continue
        _metric_fresh "speed_$d" "$SPEED_RECHECK" && continue
        local v
        v="$(measure_throughput "$d")"
        if [ -n "$v" ]; then
            _metric_set "speed_$d" "$v"
            log "测速 $d: $(fmt_bps "$v")"
        else
            # 测不到不要覆盖旧值：旧值至少是个参考，清空了连参考都没了
            log "测速 $d: 失败（保留上次结果）"
            [ -n "$(_metric_get "speed_$d")" ] || _metric_set "speed_$d" "0"
        fi
    done
}

ensure_latency() {   # $1=eth_dev $2=eth_gw $3=wifi_dev $4=wifi_gw
    local pair d gw v
    for pair in "$1:$2:eth" "$3:$4:wifi"; do
        d="${pair%%:*}"
        gw="${pair#*:}"; gw="${gw%:*}"
        [ -n "$d" ] || continue
        _metric_fresh "lat_${d}" "$LATENCY_RECHECK" && continue
        v="$(measure_latency "$d" "$gw")"
        [ -n "$v" ] && _metric_set "lat_$d" "$v"
    done
}

_metric_val() {   # $1=state 键 -> stdout: 正数（无记录/非数字/非正数都输出空）
    local v
    v="$(_metric_get "$1")"
    v="${v%% *}"
    # 非数字一律当没有
    case "$v" in ''|*[!0-9.]*) return 0 ;; esac
    # 0 和负数也当没测到。cmd_measure 会用 state_set ... 0 作废缓存，
    # 测失败就留着 0；放过它界面会显示"0 ms"/"0 Mbps"，
    # 也会让"0ms 永远赢"那类判断有更多入口。
    awk -v x="$v" 'BEGIN{ exit (x+0 > 0) ? 0 : 1 }' || return 0
    printf '%s' "$v"
}

# 按吞吐挑赢家：大的赢，差距不到 SPEED_SWITCH_RATIO 判 tie（保持现状）
pick_by_speed() {   # $1=设备A $2=BpsA $3=设备B $4=BpsB -> stdout: 设备名 | tie | 空
    awk -v d1="$1" -v a="$2" -v d2="$3" -v b="$4" -v r="$SPEED_SWITCH_RATIO" 'BEGIN{
        if (a+0 <= 0 && b+0 <= 0) { exit }              # 都没测出来
        if (a+0 <= 0) { print d2; exit }                # 只有 B 有数
        if (b+0 <= 0) { print d1; exit }
        lo = (a < b ? a : b); hi = (a < b ? b : a)
        if (hi < lo * (100 + r) / 100) { print "tie"; exit }
        print (a > b ? d1 : d2)
    }'
}

# ---------------- 入口 ----------------

main() {
    local cmd="${1:-watch}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        watch|once|run) acquire_lock; cmd_watch ;;
        status|st)      cmd_status ;;
        test|check)     cmd_test "$@" ;;
        doctor|dr)      cmd_doctor ;;
        config|conf)    cmd_config "$@" ;;
        set)            cmd_set "$@" ;;
        log)            cmd_log "$@" ;;
        balance|bal)    cmd_balance "$@" ;;
        wifi|w)         cmd_wifi "$@" ;;
        measure|m)      cmd_measure "$@" ;;
        measurements)   cmd_measurements ;;
        fixconf)        cmd_fixconf ;;
        rule)           cmd_rule "$@" ;;
        stats)          cmd_stats ;;
        report|rep)     cmd_report ;;
        quality|q)      cmd_quality ;;
        -h|--help|help) usage ;;
        *)              usage ;;
    esac
}

main "$@"

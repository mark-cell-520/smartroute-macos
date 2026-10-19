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
#   sudo smartroute set auto|ethernet|wifi|speed|latency   设置选路模式
#   sudo smartroute config       显示当前生效配置
#   smartroute log [行数]        查看日志
#
# 配置文件：
#   /etc/smartroute.conf            系统级（root 维护）
#   /Users/Shared/smartroute.conf   用户级（SmartRoute App 维护，优先级更高，无需 sudo）

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---------------- 默认配置（可被 /etc/smartroute.conf 覆盖） ----------------
MODE="auto"                 # auto | ethernet | wifi | speed | latency
                            #   auto     可用性优先：一条线没网就切到另一条（滞回，防抖）
                            #   speed    网速优先：实测吞吐大的赢；一条线没网时同样会切过去
                            #            （所以它同时覆盖"无网络自动切换"和"网速增加"）
                            #   latency  延迟优先：实测延迟低的赢，同样带可用性兜底
                            #   ethernet / wifi  固定一条线，另一条彻底不用
OK_N=2                      # 连续探测成功 N 次 → 判定“可用”
FAIL_N=3                    # 连续探测失败 N 次 → 判定“不可用”
RECONFIRM_DELAY=3           # 当前接口首次探测失败后，多久做一次当场确认（秒）
RECONFIRM_TIMES=2           # 最多当场确认几次
RECONFIRM_BUDGET=9          # 本周期内"当场确认"最多再花几秒（硬上限）
                            #
                            # 为什么必须有这个上限：非 root 下一次完整探测要
                            # ping(0.8s)+nc(2s)+curl(4s) 约 7 秒。两次确认就是
                            # 7+3+7+3 = 20 秒，正好顶到 StartInterval——下一个
                            # 守护实例会被锁挡在门外，等于白白少轮询一次，
                            # "快速"反而变成"更慢"。所以按预算截断，宁少确认一次。
COOLDOWN=45                 # 两次切换之间的最小间隔（秒），防止抖动
# 同一目标被系统推翻这么多次后，暂停抢路由。
#
# 默认值刻意调钝：实测这台机器 Wi-Fi 比有线快得多——多连接测速下
# en0 封顶 92 Mbps（100baseTX 链路），en1 能跑 270 Mbps（Wi-Fi 6 5GHz/160MHz），
# 差 3 倍左右。而系统每次都把默认路由判回**慢的那条**。
#
# （这里原先写的是"链路速率 144 Mbps vs 100 Mbps"。那个 144 是旧的错误认知，
#  已由多连接容量测试推翻：单连接测速下 en0/en1 只差 4%，看着像差不多；
#  并发压上去才看出 Wi-Fi 是 3 倍。注释里的数字和实测矛盾时，
#  后来的人会按错的先例继续推下去，所以必须一起改掉。）
# 退避触发了就意味着"停在慢线上"——那是在拿用户的速度换自己的清静。
# 所以门槛要高、暂停要短：只有真正病态的情况（短时间内推翻十几次）
# 才值得付这个代价，而且 5 分钟就重新试，不会长期困在慢线上。
# 抖动的主要来源（反复调 networksetup 重配所有网络服务）已经由
# do_switch 里"已是第一个就不重排"修掉了，不需要靠退避来兜。
FLAP_BACKOFF_AT=10
FLAP_BACKOFF=300
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
WEIGHT_RECHECK=30           # weighted 模式下重测吞吐、更新配比的轮询次数（每轮约 20 秒）
VALIDATE_MIN_BYTES=65536    # balance_validate 判定"某侧真的在扛"的字节下限
                           # Wi-Fi 关联着就有 mDNS/ARP/DHCP/iCloud 心跳，
                           # 只判 >0 会把背景流量当成分流生效的证据。
                           # 30 轮 ≈ 10 分钟。测速本身有 SPEED_RECHECK(300s) 缓存兜底，
                           # 不会每个轮询都真下载；但轮询太频会反复 pfctl -f 重建 anchor。
WIFI_FAILOVER=0             # Wi-Fi 上不了网时，自动试连其它已保存的 Wi-Fi（1 开启）
WIFI_PREFERRED=""           # 优先试连的 Wi-Fi 名（逗号分隔，靠前优先）。留空=按系统保存顺序
WIFI_FAILOVER_COOLDOWN=120  # Wi-Fi 故障转移的最小间隔（秒），防止在网络间来回跳
# 网速优先模式的测速地址，按顺序尝试，第一个能测出非零速度的胜出。
#
# 为什么从单个 URL 改成列表：单一 URL 是单点故障，而本项目已经被它坑过多次——
#   · Cloudflare 的 __down 忽略 Range（越界 Range 返 200），4 条并发连接
#     在下同一个完整文件，测出来是噪声；
#   · 它对国内网络时段性劣化，实测单连接从 15 Mbps 掉到 3 Mbps；
#   · proof.ovh.net 累计下载约 2GB 后开始限流，64 个请求全军覆没。
# 一个测速源不可用，"网速优先"模式就整个失灵——而它失灵时的表现是
# 测出 0 或不切换，用户看不出是源坏了还是线坏了。
#
# 排序原则：国内镜像优先（实测稳定、且对并发友好），Cloudflare 兜底。
SPEED_TEST_URLS="https://mirrors.aliyun.com/debian/dists/stable/main/binary-amd64/Packages.gz https://mirrors.tuna.tsinghua.edu.cn/debian/dists/stable/main/binary-amd64/Packages.gz https://mirrors.ustc.edu.cn/debian/dists/stable/main/binary-amd64/Packages.gz https://speed.cloudflare.com/__down?bytes=5000000"
SPEED_TEST_URL="${SPEED_TEST_URLS%% *}"   # 兼容旧引用（单值处）
SPEED_TEST_TIMEOUT=8        # 单次测速超时（秒）
SPEED_RECHECK=300           # 多久重新测一次网速（秒）。测速要真下载，太频繁费流量
LATENCY_DEGRADE_RATIO=2     # 当前线路延迟是另一条的这个倍数以上，视为"可能变慢"，
                            # 提前重测吞吐（延迟探测只要几个包，比真下载便宜得多）
LATENCY_RECHECK=60          # 多久重新测一次延迟（秒）
SPEED_SWITCH_RATIO=30       # 判定"明显更快"的吞吐差阈值（百分比）。低于它就继续用当前线路，
                            # 避免在两条差不多的线路间来回切

# 可用 set 命令修改的配置项
VALID_KEYS="MODE OK_N FAIL_N COOLDOWN PROBE_TARGETS PING_TIMEOUT NC_TIMEOUT TLS_PROBE NOTIFY AUTO_WIFI_POWER BALANCE BALANCE_MODE FASTEST_SWITCH_RATIO WIFI_FAILOVER WIFI_PREFERRED WIFI_FAILOVER_COOLDOWN SPEED_TEST_URL SPEED_TEST_TIMEOUT SPEED_RECHECK LATENCY_RECHECK SPEED_SWITCH_RATIO FASTEST_RECHECK WEIGHT_RECHECK SPEED_TEST_URLS"

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
        # weighted 必须在白名单里。以前漏了它，而 balance_on 自己会
        # conf_set_auto BALANCE_MODE weighted ——于是工具写进去的值，
        # 下一次重新加载配置时（守护进程每 20 秒、或任何新进程）被解析层
        # 丢弃、回落默认 round-robin。后果：
        #   · smartroute config 同屏自相矛盾："当前生效配置"显示 round-robin，
        #     下方"配置文件内容"显示 weighted
        #   · set BALANCE_MODE=weighted 被拒（提示"只能是 round-robin|fastest"），
        #     尽管这个值是工具自己生成的
        #   · weighted 会话之后裸跑 balance on，静默变成 round-robin
        BALANCE_MODE)  case "$val" in round-robin|fastest|weighted) ;; *) return 1 ;; esac ;;
        OK_N|FAIL_N|COOLDOWN|PING_TIMEOUT|NC_TIMEOUT|FASTEST_SWITCH_RATIO|FASTEST_RECHECK|WIFI_FAILOVER_COOLDOWN|SPEED_TEST_TIMEOUT|SPEED_RECHECK|LATENCY_RECHECK|SPEED_SWITCH_RATIO)
                       case "$val" in ''|*[!0-9]*) return 1 ;; esac ;;
        TLS_PROBE|NOTIFY|AUTO_WIFI_POWER|BALANCE|WIFI_FAILOVER)
                       case "$val" in 0|1) ;; *) return 1 ;; esac ;;
        PROBE_TARGETS) case "$val" in *[!0-9.\ ]*) return 1 ;; esac ;;
        WIFI_PREFERRED) case "$val" in *[$'\n\r']*) return 1 ;; esac ;;
        # 必须限 http/https。以前只判非空，于是配置文件里可以放任意字符串，
        # 而它会被原样交给 curl --interface 去下载。攻击者能借此让 root
        # 的 curl 去打内网地址、或消耗带宽。限制协议后最坏也只是指向一个
        # 公网 HTTP 地址，与"用户自己配错了测速地址"同级。
        SPEED_TEST_URL) case "$val" in http://*|https://*) [ -n "$val" ] || return 1 ;; *) return 1 ;; esac ;;
        # 列表里每个条目都要限协议。只整体判非空是不够的：列表按空格拆分后
        # 逐条交给 curl，任一条是 file:// 或内网地址都会被执行。
        SPEED_TEST_URLS)
            case "$val" in *[!\ ]*) ;; *) return 1 ;; esac
            local _u
            for _u in $val; do
                case "$_u" in http://*|https://*) ;; *) return 1 ;; esac
            done
            ;;
        *) return 1 ;;
    esac
    return 0
}

# 每个键的取值说明（错误提示用）。校验本身在 conf_value_ok，
# 这里只负责"说清楚该填什么"——两者分开，免得改提示时不小心改松了校验。
conf_value_hint() {   # $1=key -> stdout: 说明
    case "$1" in
        MODE)          echo "MODE 只能是 auto|ethernet|wifi|speed|latency" ;;
        BALANCE_MODE)  echo "BALANCE_MODE 只能是 round-robin|fastest|weighted" ;;
        OK_N|FAIL_N|COOLDOWN|PING_TIMEOUT|NC_TIMEOUT|FASTEST_SWITCH_RATIO|FASTEST_RECHECK|WIFI_FAILOVER_COOLDOWN|SPEED_TEST_TIMEOUT|SPEED_RECHECK|LATENCY_RECHECK|SPEED_SWITCH_RATIO)
                       echo "$1 必须是非负整数" ;;
        TLS_PROBE|NOTIFY|AUTO_WIFI_POWER|BALANCE|WIFI_FAILOVER)
                       echo "$1 只能是 0 或 1" ;;
        PROBE_TARGETS) echo "PROBE_TARGETS 只能是空格分隔的 IP" ;;
        WIFI_PREFERRED) echo "WIFI_PREFERRED 不能含换行" ;;
        SPEED_TEST_URL) echo "SPEED_TEST_URL 不能为空" ;;
        SPEED_TEST_URLS) echo "SPEED_TEST_URLS 不能为空，且每个条目都必须是 http/https 地址" ;;
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
    # root 守护进程每 20 秒解析这个文件，而它位于 /Users/Shared（1777）。
    # install.sh 以前从不创建它，于是文件不存在时**任何本地用户都能建一个**，
    # 让 root 按他的配置选路/测速。即使建了，权限一旦被放宽同样成立。
    # 这里做纵深防御：群/他人可写的配置直接不解析。
    # 合法场景不受影响——install.sh 现在会以 644 创建它（见 install.sh），
    # App 和 smartroute set 写的也是同一属主。
    local _perm
    _perm="$(ls -ld "$f" 2>/dev/null | cut -c1-10)"
    case "$_perm" in
        ?rw?w?*|????????w*|??????????)
            # 只精确判 group-write / other-write 两位，避免误伤
            case "$_perm" in
                ??????w?*|?????????w) log "跳过配置 ${f}：群/他人可写（${_perm}），拒绝解析" ; return 0 ;;
            esac ;;
    esac
    while IFS= read -r line || [ -n "$line" ]; do
        # 去掉行尾 CR（配置文件被 Windows 编辑器改过的情况）
        line="${line%$'\r'}"
        case "$line" in ''|\#*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        k="${line%%=*}"; v="${line#*=}"
        # 键名两端都要 trim，而且必须用"去头/去尾成对"的写法。
        # 以前是 k="${k%%[[:space:]]*}"; k="${k##[[:space:]]}" ——
        # 第一招在键名**左侧**有空格时会把整个键削成空串
        # （%%[[:space:]]* 从第一个空格一直删到尾），于是整行被当成
        # 未知键静默跳过。缩进的配置行就是这么丢的。
        # 正确做法：先删掉"开头那段纯空白"，再删掉"结尾那段纯空白"。
        k="${k#"${k%%[![:space:]]*}"}"
        k="${k%"${k##*[![:space:]]}"}"
        # 值也要 trim。`KEY = value`（等号两边带空格）是很自然的写法，
        # 但以前不 trim：v 变成 " value"，数字键撞 *[!0-9]* 被静默丢弃，
        # 计数器/超时类参数从不上报——用户改了配置却没有任何效果，
        # 也看不到任何提示。mode 类的值则是前后带空格直接不匹配。
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
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
        # 记下"这个键是用户显式配的"。测速要用它判断优先级：
        # 用户配了 SPEED_TEST_URL（单值）时不该被脚本默认的
        # SPEED_TEST_URLS 列表静默覆盖——否则他改了配置、重启守护进程、
        # 发现测速结果毫无变化，会以为工具没生效。
        # 判据必须是"用户配过"，不能比较字符串：用户完全可能把值配得
        # 和默认第一个一模一样，那是他的权利，一样应当被尊重。
        _CONF_SET_KEYS="${_CONF_SET_KEYS:+$_CONF_SET_KEYS }$k"
    done < "$f"
    return 0
}

# 某个键是否由用户在配置文件里显式设置过
_conf_set() {
    case "${_CONF_SET_KEYS:-}" in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
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
  set          设置选路模式: auto | ethernet | wifi | speed | latency；也可 set KEY=VALUE（如 NOTIFY=1，普通用户可写用户级配置）
  boost        一键配好四项能力：无网络自动切换 + 网速优先 + 双网并发 + Wi-Fi 自动寻找
  config       显示当前生效配置（含两个配置文件内容）
  log [N]      查看最近日志（log 40 或 log --lines 40，默认 50 行）

双网并发 / 分流:
  balance on [round-robin|fastest|weighted]
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

# 设备名 -> 人话。通知是给用户看的，而 "en0"/"en1" 对非技术用户毫无意义——
# 开了通知的人收到"默认路由: en1 → en0"，只会更困惑：en1 是什么？
# 我刚刚被切去了哪里？所以所有通知都要过这个函数。
dev_cn() {
    case "$1" in
        en0) echo "以太网（有线）" ;;
        en1) echo "Wi-Fi（无线）" ;;
        en2|en3|en4|en5) echo "网卡 $1" ;;
        "")  echo "无" ;;
        *)   echo "$1" ;;
    esac
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
    # 加成功就记一笔：本次进程真的往路由表里加了东西。
    # EXIT trap 靠这个标志决定要不要 cleanup_probe_routes——没加过就清什么，
    # 而无条件清会删掉守护进程探测途中的路由（见 _smartroute_cleanup 的注释）。
    if route add -host "$1" -interface "$2" "$3" >/dev/null 2>&1; then
        PROBE_ROUTES_ADDED=1; return 0
    fi
    if route add -host "$1" "$3" -interface "$2" >/dev/null 2>&1; then
        PROBE_ROUTES_ADDED=1; return 0
    fi
    if route add -host "$1" "$3" >/dev/null 2>&1; then
        PROBE_ROUTES_ADDED=1; return 0
    fi
    # 目标路由已存在（同网段双宿主、残留路由，或与守护进程的探测并发时会出现）。
    # 复用已有路由的前提是它真的是"同一条上网路径"——**网关和接口都必须一致**。
    #
    # 以前只比网关，这是个坑：两个口接同一台路由器时网关本来就相同
    # （这台机器就是 192.168.1.1），于是已存在的、指向另一个接口的路由
    # 也被判定为"可复用"。调用方以为探测会走指定网卡，实际走了另一条，
    # 测出来的延迟/吞吐全是对的接口的错数据。
    local cur curif
    cur="$(route -n get "$1" 2>/dev/null | sed -n 's/^[[:space:]]*gateway:[[:space:]]*//p' | head -1)"
    curif="$(route -n get "$1" 2>/dev/null | sed -n 's/^[[:space:]]*interface:[[:space:]]*//p' | head -1)"
    if [ -n "$cur" ] && [ "$cur" = "$3" ] && [ "$curif" = "$2" ]; then
        return 0
    fi
    return 1
}

route_add_default() {  # $1=设备 $2=网关
    # 第三条兜底不能不带 -interface。`route add default $gw` 只指定网关，
    # 内核按自己的路由表选出口，很可能落到另一个接口上——而函数返回 0，
    # 调用方（do_switch）据此打出"切换默认路由: X -> Y"、"✅ 已切换"。
    # 用户看到成功，实际默认路由没动。这是假成功。
    #
    # 现在：先验证默认路由的出口确实是目标设备，不是就承认失败。
    # 失败会让 do_switch 走原有的失败路径（记 flap、不清 flap_count），
    # 而不是谎报成功。
    route add default -interface "$1" "$2" 2>/dev/null && return 0
    route add default "$2" -interface "$1" 2>/dev/null && return 0
    # 兜底仍然尝试一次（某些 macOS 版本对参数顺序挑剔），但必须验证出口
    if route add default "$2" 2>/dev/null; then
        local _out
        _out="$(route -n get default 2>/dev/null | awk '/^ *interface:/{print $2; exit}')"
        if [ "$_out" = "$1" ]; then
            return 0
        fi
        # 出口不对：把这条错的撤掉，别留一条指向错误接口的默认路由
        route delete default "$2" >/dev/null 2>&1
        log "route_add_default: 兜底成功但出口是 ${_out:-未知}（期望 $1），已撤销"
        return 1
    fi
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
        # 每个目标都要**验证包真的会从 $dev 出去**，不能只信 route_add_host
        # 的返回值。它的兜底分支是"已存在同网关的路由就复用"，而这台机器
        # 两个口接同一台路由器（同网关 192.168.1.1）——那条已存在的路由
        # 很可能指向另一个接口。复用之后 ping 走错口，测到的是另一条线的
        # 延迟，latency/fastest 模式会据此选错线。
        #
        # 宁可少测几个目标，也不能拿假数据做决策。全部目标都指不进去时
        # 返回空（调用方按"测不出"处理，保持现状），而不是返回一个
        # 属于别的接口的数字。
        local _ok="" _nok=0 _via
        for t in $seen; do
            route_add_host "$t" "$dev" "$gw" >/dev/null 2>&1 || continue
            _via="$(route -n get "$t" 2>/dev/null | sed -n 's/^[[:space:]]*interface:[[:space:]]*//p' | head -1)"
            # _via 为空说明没探到出口，交给 route_add_host 的判断；
            # 非空且不是目标设备，才是确凿的走错口。
            if [ -n "$_via" ] && [ "$_via" != "$dev" ]; then
                continue
            fi
            _ok="$_ok $t"; _nok=$((_nok+1))
        done
        if [ "$_nok" -eq 0 ]; then
            cleanup_probe_routes >/dev/null 2>&1
            return 1
        fi
        seen="$_ok"
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

    # ── 三轮探测：并行发出，但不等全部，谁先通谁算 ──
    #
    # 原来的写法是串行 + break，代价实测（去重后 7 个目标）：
    #
    #     常见（第一个 ping 就通）   0.03s     ← 这种情况串行已经最优
    #     坏（ICMP 全禁）            5.6s(ping) + 28s(TCP) + 8s(TLS) = 42s
    #
    # 而守护进程 StartInterval 是 20 秒，两个接口各 42 秒 = 83 秒，
    # 是轮询间隔的 4 倍——**于是守护进程永远在探测，没有一秒空闲**。
    #
    # 所以两件事都要做，缺一不可：
    #   1) 坏情况要并行（42s → 6.8s）
    #   2) 常见情况不能变慢
    #
    # 第一版我只做了并行 + wait 全部，结果常见情况从 0.03s 变成 1.95s
    # （等 7 个 ping 里最慢的那个）——**慢 60 倍，是真实的回归**。
    # 已实测抓到。所以正确做法是：并行发出 + 轮询等第一个成功，
    # 常见情况仍然 ~0.03s 收手，坏情况由并行把上界压到最慢那一个。
    local _T; _T="$(mktemp -d /tmp/smartroute_probe.XXXXXX)" || _T=""

    # 在临时目录里轮询等"任一匹配前缀的文件出现"。
    # $1=目录 $2=前缀 $3=超时（**秒**，必须是秒）-> 0 表示有任意一个成功了
    #
    # 单位这里栽过一次：PING_TIMEOUT=800 是**毫秒**（ping -W 用的单位），
    # 我直接把它传给这个按秒计的函数，于是 800×20×0.05s = 800 秒——
    # 一次探测要跑 13 分钟，实测基准测试跑出 2253 秒才发现。
    # 现在调用方必须显式换算，并且这个函数自己校验上界：
    # 超过 60 秒一律按 60 秒算，防止再有个毫秒值混进来把探测挂死。
    _probe_wait_any() {
        local _d="$1" _pre="$2" _tmo="$3" _i=0 _n _f
        case "$_tmo" in ''|*[!0-9]*) _tmo=5 ;; esac
        [ "$_tmo" -ge 1 ] || _tmo=1
        [ "$_tmo" -le 60 ] || _tmo=60
        _n=$(( _tmo * 20 ))          # 50ms 一轮
        while [ "$_i" -lt "$_n" ]; do
            for _f in "$_d/$_pre"*; do
                [ -f "$_f" ] && return 0
            done
            sleep 0.05
            _i=$(( _i + 1 ))
        done
        return 1
    }

    # 杀掉一批后台探测进程。早退成功后必须调——不杀的话裸 wait 会
    # 等到最慢那一个，把并行省下的时间全还回去（实测 0.024s → 1.954s）。
    # 已经跑完的 PID kill 会失败，忽略即可。
    _probe_kill_pids() {
        local _p
        for _p in $1; do
            kill "$_p" 2>/dev/null
        done
        return 0
    }

    # 第一轮 ping：**串行试前两个，都不通才并行剩下的**。
    #
    # 为什么不能一上来就并行：常见情况第一个目标 30ms 就回，
    # 串行 + break 就是 0.03s，已经最优。并行反而更慢——
    #   · 轮询等第一个成功，粒度是 sleep 0.05，最少也要 50ms
    #   · 早退后还得 kill 剩余进程，又是几次系统调用
    # 实测（5 次平均）：串行 0.030s / 并行+早退 0.109s / 并行+wait 全部 1.954s。
    # 并行只在"前两个都不通"时才划算——那种情况串行要 7×800ms=5.6s，
    # 并行只要 0.8s。而那种情况本来就是少数（ICMP 被禁的网络）。
    #
    # 所以：串行试前 2 个（覆盖绝大多数情况，且成本最低），
    # 都不通再并行发剩余 5 个（把最坏情况从 5.6s 压到 0.8s）。
    if [ -n "$_T" ]; then
        _tried=""
        _n=0
        for t in $targets; do
            _tried="$_tried $t"
            _n=$(( _n + 1 ))
            if ping -c 1 -W "$PING_TIMEOUT" "$t" >/dev/null 2>&1; then
                ping_ok=1; ok=0; : > "$_T/ping_$t"; break
            fi
            [ "$_n" -ge 2 ] && break
        done
        # 前两个都没通 → 并行发剩下的。此时串行已花掉 ~1.6s，
        # 再串行下去还要 4s；并行只要 0.8s。
        if [ "$ping_ok" -ne 1 ] && [ -n "$_T" ]; then
            _pids=""
            for t in $targets; do
                case " $_tried " in *" $t "*) continue ;; esac
                ( ping -c 1 -W "$PING_TIMEOUT" "$t" >/dev/null 2>&1 && : > "$_T/ping_$t" ) &
                _pids="$_pids $!"
            done
            # PING_TIMEOUT 是毫秒，这里换算成秒（向上取整，至少 1 秒）
            _pt_s=$(( (PING_TIMEOUT + 999) / 1000 ))
            [ "$_pt_s" -ge 1 ] || _pt_s=1
            if _probe_wait_any "$_T" "ping_" "$_pt_s"; then
                ping_ok=1; ok=0
                _probe_kill_pids "$_pids"
            else
                wait 2>/dev/null
            fi
            for t in $targets; do [ -f "$_T/ping_$t" ] && { ping_ok=1; break; }; done
        fi
    fi

    # 第二轮 TCP 兜底（ICMP 被禁时走）。14 个连接并行发，等第一个成功。
    # 最坏从 28s 降到 2s。
    if [ "$ok" -ne 0 ] && [ -n "$_T" ]; then
        _pids=""
        for t in $targets; do
            for p_ in 53 443; do
                ( nc -z -w "$NC_TIMEOUT" "$t" "$p_" >/dev/null 2>&1 && : > "$_T/tcp_${t}_${p_}" ) &
                _pids="$_pids $!"
            done
        done
        if _probe_wait_any "$_T" "tcp_" "$NC_TIMEOUT"; then
            tcp_ok=1; ok=0
            _probe_kill_pids "$_pids"
        else
            wait 2>/dev/null
        fi
        for t in $targets; do
            for p_ in 53 443; do
                [ -f "$_T/tcp_${t}_${p_}" ] && { tcp_ok=1; break 2; }
            done
        done
    fi

    # 第三轮 TLS 握手（确认是"真互联网"，能过证书校验）。2 个并行发。
    if [ "$ok" -ne 0 ] && [ "$TLS_PROBE" = "1" ] && command -v curl >/dev/null 2>&1 && [ -n "$_T" ]; then
        _pids=""
        for t in 1.1.1.1 8.8.8.8; do
            case " $targets " in *" $t "*) ;; *) continue ;; esac
            ( curl -s -m 4 -o /dev/null "https://$t/" 2>/dev/null && : > "$_T/tls_$t" ) &
            _pids="$_pids $!"
        done
        if _probe_wait_any "$_T" "tls_" 4; then
            tls_ok=1; ok=0
            _probe_kill_pids "$_pids"
        else
            wait 2>/dev/null
        fi
        for t in 1.1.1.1 8.8.8.8; do
            case " $targets " in *" $t "*) ;; *) continue ;; esac
            [ -f "$_T/tls_$t" ] && { tls_ok=1; break; }
        done
    fi

    [ -n "$_T" ] && rm -rf "$_T"

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

# 原始网络服务顺序的备份文件路径。
# 用单独的文件而不是 state：服务名可能含空格（如 "Thunderbolt Bridge"），
# 用空格/逗号拼进 state 的 key=value 会歧义；一行一个最稳。
SVC_ORDER_BAK="${STATE_FILE%/*}/svc_order_orig"

# reorder_first 会把当前首选服务挪到服务顺序第一位，而
# networksetup -ordernetworkservices 是**持久化**修改——重启、重连网络都还在，
# 卸载本软件也不会自动还原。用户在系统设置>网络里发现顺序被动过，却不知道
# 是谁干的；而卸载脚本最后还告诉他"网络设置未改动"，对不上就彻底没信任了。
# 所以：第一次改之前先把原始顺序存下来，卸载时据此还原。
svc_order_backup_once() {
    [ -s "$SVC_ORDER_BAK" ] && return 0        # 只存第一次，别把已改过的又存一遍
    local d
    d="$(dirname "$SVC_ORDER_BAK")"
    mkdir -p "$d" 2>/dev/null || return 0
    if ordered_service_names > "$SVC_ORDER_BAK" 2>/dev/null && [ -s "$SVC_ORDER_BAK" ]; then
        log "已备份原始网络服务顺序（${SVC_ORDER_BAK}），卸载时可还原"
    else
        rm -f "$SVC_ORDER_BAK" 2>/dev/null      # 存了个空的比没存更糟
    fi
}

# 把某个服务挪到服务顺序第一位（其余保持相对顺序）
reorder_first() {   # $1=服务名
    local primary="$1" svc
    local rest=()
    svc_order_backup_once
    # 已经是第一个就立刻返回，不要调 networksetup。
    #
    # 这个命令会重排并重配**所有**网络服务，是重量级操作。实测一台机器上
    # 它被调了 105 次：macOS 不停把默认路由判回以太网，工具不停抢回来，
    # 而每次抢都跑一遍完整的服务重排——顺序本来就一直是对的，纯属白干，
    # 还把网络抖得厉害。用户体感是"这工具在卡我的网"。
    # 调用方靠 REORDER_NOOP 区分"真调整了"和"本来就是对的"，
    # 从而跳过那 2 秒等待（见 do_switch）。
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

    # 检测"系统反复把默认路由判回同一个接口"。
    #
    # 实测这台机器：51 次 en0 -> en1，只有 7 次反向。这不是抖动，是 macOS
    # 每次都把默认路由重新判回以太网、工具再改回来。用户感受就是
    # "以太网卡主"，而工具一声不响地反复改了几十次——他既不知道发生了什么，
    # 也不知道能做什么。
    #
    # 两个接口同网段/同网关时，configd 的默认路由裁决会倾向于同一个接口，
    # 于是这个循环会一直转。说清楚，比继续沉默地改有用。
    local flap_last flap_n flap_gap last_ts
    flap_last="$(state_get flap_target)"
    flap_n="$(state_get flap_count)"
    [[ "$flap_n" =~ ^[0-9]+$ ]] || flap_n=0
    # last_switch 首次运行是空的。直接塞进 $(( now - )) 会算术报错，
    # 把整个函数中断——于是第一次切换静默失败。冷却期那段早就这么防了。
    last_ts="$(state_get last_switch)"
    [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0
    flap_gap=$(( $(date +%s) - last_ts ))
    # 半小时内连续切到同一个目标才算"反复"；间隔久了只是偶发，别冤枉用户
    if [ "$flap_last" = "$want" ] && [ "$flap_gap" -le 1800 ]; then
        flap_n=$((flap_n+1))
    else
        flap_n=1
    fi
    state_set flap_target "$want"
    state_set flap_count "$flap_n"
    if [ "$flap_n" -eq 3 ]; then
        # 第 3 次才说——前两次可能真是网络波动，别急着下结论
        log "注意：默认路由第 3 次被系统判回 ${cur}，已再次切到 $want"
        log "  若两个接口同网段或同网关，系统会反复这样裁决；可按状态页提示调整网络"
        notify "SmartRoute 选路不稳定" "macOS 已第 3 次把默认路由改回 $(dev_cn "${cur:-}")。若网线和 Wi-Fi 接同一台路由器，系统会反复这样判——请看状态页的提示。"
    elif [ "$flap_n" -gt 3 ] && [ $((flap_n % 10)) -eq 0 ]; then
        # 之后每 10 次提一次，不刷屏
        log "注意：默认路由已被系统改回 ${cur} 累计 $flap_n 次"
        notify "SmartRoute 选路不稳定" "macOS 已累计 $flap_n 次把默认路由改回 $(dev_cn "${cur:-}")。若网线和 Wi-Fi 接同一台路由器，系统会反复这样判——请看状态页的提示。"
    fi

    # 一进来就记尝试时间。原来只在两条成功路径的末尾才写 last_switch，
    # 失败的尝试不落时间——于是冷却期形同虚设：目标接口持续不可用时，
    # 每 20 秒就重试一次，每次都走一遍"删默认路由再添加"。
    # 失败的尝试同样会动路由表，一样该被节流。
    state_set last_switch "$(date +%s)"

    # 1) 首选：调整服务顺序（持久，网络重连后依然有效）
    #
    # 但**已经是第一个就别调**。networksetup -ordernetworkservices 会重排并
    # 重配所有网络服务，是重量级操作。实测一台机器上它被调了 105 次：
    # macOS 不停把默认路由判回以太网、工具不停抢回来，而每次抢都跑一遍
    # 完整的服务重排——顺序本来就一直是对的，纯属白干，还把网络抖得厉害。
    # 用户体感是"这工具在卡我的网"。
    #
    # 判断放在这里而不是 reorder_first 里：那个函数的契约是"总是重排"，
    # 在里面加早退会让它的参数拼装逻辑测不到（现有测试全红）。
    local _need_reorder=1
    if [ -z "$svc" ]; then
        _need_reorder=0
    elif [ "$(ordered_service_names | head -1)" = "$svc" ]; then
        _need_reorder=0
    fi
    if [ "$_need_reorder" = "1" ] && reorder_first "$svc"; then
        sleep 2
        now="$(default_dev)"
        if [ "$now" = "$want" ]; then
            log "完成：服务顺序已调整，默认路由 -> $now"
            state_set last_switch "$(date +%s)"
            bump_switch_count
            notify "SmartRoute 选路切换" "已从 $(dev_cn "${cur:-}") 切换到 $(dev_cn "$want")"
            return 0
        fi
        log "服务顺序已调整但默认路由仍为 ${now:-无}，尝试直接修改路由表"
    elif [ "$_need_reorder" = "0" ] && [ -n "$svc" ]; then
        # 顺序已经没有可调整的空间了，但**先确认默认路由是不是已经对了**。
        # 顺序对、路由也对的情况很常见（上一轮刚调好，这轮在被判回来之前）。
        # 少了这一步会明明已经对了还去删/加默认路由——纯粹的白白中断网络。
        now="$(default_dev)"
        if [ "$now" = "$want" ]; then
            # 顺序已经是对的、默认路由也已经是对的——这一轮什么都没做。
            # 别发"已切换"通知：用户什么都没感觉到，却收到一条切换通知，
            # 只会让他怀疑工具在谎报。宁可安静，也不要假成功。
            # 也不写 last_switch：没动过路由表，没有需要节流的重试。
            log "默认路由已是 ${now}（${svc} 优先），无需调整"
            return 0
        fi
        log "服务顺序已是 $svc 优先，无需重排；直接修改路由表"
    else
        log "无法通过服务顺序切换（服务名:${svc:-无}），尝试直接修改路由表"
    fi

    # 2) 兜底：直接改路由表，立即生效（configd 之后若重建默认路由，下次 watch 会再修正）
    gw="$(svc_router "$svc")"
    if [ -n "$gw" ]; then
        # 先把当前默认路由的参数记下来。原来是先 route delete default 再 add，
        # 而 add 有三条命令、任一条都不保证成功（路由表被占、网关不可达、
        # 权限问题都会失败）。一旦 add 失败，系统就**没有默认路由了**——
        # 不是"切过去失败"，是整台机器断网，而且不会自己恢复。
        # 所以：记下原参数，加失败就原样加回去。宁可切换没做成，也不能让人掉线。
        local bak_if bak_gw
        bak_if="$(default_dev)"
        bak_gw="$(default_gw)"
        route delete default >/dev/null 2>&1
        if route_add_default "$want" "$gw"; then
            log "完成：路由表已改为 default via $gw ($want)"
            state_set last_switch "$(date +%s)"
            bump_switch_count
            notify "SmartRoute 选路切换" "已从 $(dev_cn "${cur:-}") 切换到 $(dev_cn "$want")"
        else
            log "失败：无法添加 default via $gw ($want)，尝试恢复原默认路由"
            if [ -n "$bak_if" ] && [ -n "$bak_gw" ] && route_add_default "$bak_if" "$bak_gw"; then
                log "已恢复原默认路由：$bak_if via $bak_gw"
            else
                # 恢复也失败：这时候必须说清楚，让人立刻知道该做什么。
                # 静默留在一个没有默认路由的状态是最糟的。
                log "严重：无法恢复默认路由（原 ${bak_if} via ${bak_gw}）。请手动执行：sudo route add default ${bak_gw} -interface ${bak_if}"
            fi
        fi
    else
        log "失败：目标接口没有网关信息"
    fi
}

# ---------------- 命令实现 ----------------
cmd_watch() {
    find_active
    # now 必须在函数作用域声明。原来它只在 if 分支里 local now last，
    # 于是走 elif（本轮无需切换）分支时 now 从未赋值——算术表达式里
    # 未初始化变量按 0 算，"距上次切换 $((now - _last))" 永远是个大负数，
    # 抖动计数的清零永远不触发。这个分支恰恰是修 flap 振荡的关键路径。
    local eth_res="na" wifi_res="na" _p _last now
    # probe_dev 输出两行：第 1 行判定，第 2 行明细。这里只取判定行。
    if [ -n "$ACTIVE_ETH_DEV" ]; then
        eth_res="$(probe_dev "$ACTIVE_ETH_DEV" "$(svc_router "$ACTIVE_ETH_SVC")" | sed -n 1p)"
    fi
    if [ -n "$ACTIVE_WIFI_DEV" ]; then
        wifi_res="$(probe_dev "$ACTIVE_WIFI_DEV" "$(svc_router "$ACTIVE_WIFI_SVC")" | sed -n 1p)"
    fi

    local se sw eth_ok wifi_ok cur want _rc_eth=0 _rc_wifi=0 _rc_role _rc_dev _rc_svc _rc_n _rc_res
    cur="$(default_dev)"

    # 【快速故障转移】当前接口探测失败时，不要干等下一个 20 秒周期。
    #
    # 原来的时序：FAIL_N=3 个周期 × StartInterval 20 秒 = 最少 60 秒才切换。
    # 用户体感是"网断了快一分钟才恢复"——这正是"一个没网络，另一个不能
    # 快速接上"的根因。
    #
    # 现在：本周期内连续确认 RECONFIRM_TIMES 次，每次都失败就记一笔，
    # 持续断网的检测时间降到约 26 秒（第 2 轮 20s + 周期内 10s 确认）。
    # 代价只在真的出问题时才付——健康时一次都不多跑。
    #
    # 为什么不是"失败就立刻切"：一次探测失败可能只是几秒抖动（DNS 抽风、
    # AP 重连、系统忙）。坐实到 3 笔再动，避免把用户莫名其妙切到另一条线——
    # 那种情况下他宁愿多等十几秒。
    local _rc_role="" _rc_dev="" _rc_svc=""
    if [ "$cur" = "$ACTIVE_ETH_DEV" ] && [ "$eth_res" = "fail" ] && [ -n "$ACTIVE_ETH_DEV" ]; then
        _rc_role="eth";  _rc_dev="$ACTIVE_ETH_DEV";  _rc_svc="$ACTIVE_ETH_SVC"
    elif [ "$cur" = "$ACTIVE_WIFI_DEV" ] && [ "$wifi_res" = "fail" ] && [ -n "$ACTIVE_WIFI_DEV" ]; then
        _rc_role="wifi"; _rc_dev="$ACTIVE_WIFI_DEV"; _rc_svc="$ACTIVE_WIFI_SVC"
    fi

    if [ -n "$_rc_role" ]; then
        local _rc_n=0 _rc_res="fail" _rc_deadline
        _rc_deadline=$(( $(date +%s) + RECONFIRM_BUDGET ))
        while [ "$_rc_n" -lt "$RECONFIRM_TIMES" ]; do
            # 预算用尽就停：剩下的交给下一个周期。少确认一次只是慢一点，
            # 侵占下一个周期会让守护进程整体轮询变稀，得不偿失。
            [ "$(date +%s)" -ge "$_rc_deadline" ] && {
                log "${_rc_role} 当场确认已达 ${RECONFIRM_BUDGET}s 预算上限，剩余交由下一轮"
                break
            }
            sleep "$RECONFIRM_DELAY"
            # 用 probe_dev 而不是只 ping：有些网络/路由器禁 ICMP，ping 永远不通
            # 但链路是好的。只 ping 会把"禁 ping 的网络"误判成恢复，从而停止加速。
            _rc_res="$(probe_dev "$_rc_dev" "$(svc_router "$_rc_svc")" | sed -n 1p)"
            if [ "$_rc_res" != "fail" ]; then
                log "${_rc_role} 当场确认恢复，不加速判定"
                break
            fi
            _rc_n=$((_rc_n+1))
            log "${_rc_role} 第 ${_rc_n} 次当场确认仍失败，加速判定"
        done
        if [ "$_rc_role" = "eth" ]; then
            [ "$_rc_res" != "fail" ] && eth_res="$_rc_res"
            _rc_eth="$_rc_n"
        else
            [ "$_rc_res" != "fail" ] && wifi_res="$_rc_res"
            _rc_wifi="$_rc_n"
        fi
    fi

    se="$(update_streak eth "$eth_res")"
    sw="$(update_streak wifi "$wifi_res")"
    # 当场确认失败的每一次都要记一笔。少了这一步，快速确认就只是"白等几秒
    # 然后照样只记一笔"，检测时间一点没缩短。
    # 记满 RECONFIRM_TIMES 笔后停：再加就逼近 StartInterval 了，
    # 下一个实例会被锁挡在门外，反而少轮询一次。
    local _i=0
    while [ "$_i" -lt "$_rc_eth" ]; do se="$(update_streak eth fail)"; _i=$((_i+1)); done
    _i=0
    while [ "$_i" -lt "$_rc_wifi" ]; do sw="$(update_streak wifi fail)"; _i=$((_i+1)); done

    # 【保护】默认路由若由 VPN/拨号等第三方接口持有（utun/ppp/ipsec），不干预——
    # 那种情况下流量本来就走在隧道里，改服务顺序/路由表没有意义甚至有害。
    #
    # ⚠️ 但"不干预"只适用于服务顺序/路由表那套单网选路逻辑。
    # 双网并发的安全阀不能跟着一起跳过：VPN 持有默认路由时，
    # 若某个物理口没有外网，pf route-to 仍会把一半新连接送进那个死口，
    # 而且会把去往 VPN 目标的流量劫持到物理接口（隧道泄漏）。
    # balance_on 只在开启时查过 VPN，之后连上 VPN 不会再查——
    # 所以这里必须自己判，不能提前 return。
    if [ -n "$cur" ] && [ "$cur" != "$ACTIVE_ETH_DEV" ] && [ "$cur" != "$ACTIVE_WIFI_DEV" ]; then
        echo "$(ts) default=$cur 由 VPN/其他接口持有，不干预服务顺序"
        if [ "$BALANCE" = "1" ] && [ "$(id -u)" -eq 0 ]; then
            log "VPN/其他接口 ($cur) 持有默认路由，关闭双网并发避免隧道泄漏"
            balance_off quiet
            notify "SmartRoute 双网并发" "VPN 接管了默认路由，已自动关闭双网并发（避免流量被分流到物理接口）"
        fi
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
            # 说明白为什么关——用户可能根本没开过这个开关，突然收到"已关闭"会很慌
        notify "SmartRoute 双网并发" "有个接口上不了网，已自动关闭双网并发，改为单线路选路"
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
        elif [ "$(state_get balance_mode)" = "weighted" ]; then
            # 权重模式：周期性重测吞吐并更新配比。只在权重真的变了时才重写规则。
            local bwcyc
            bwcyc=$(( $(state_get balance_wcycle) + 1 ))
            state_set balance_wcycle "$bwcyc"
            if [ "$bwcyc" -ge "$WEIGHT_RECHECK" ]; then
                state_set balance_wcycle 0
                balance_weight_reevaluate
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
        # 补上原因。用户在手动关掉 Wi-Fi 的场景下收到"已自动打开 Wi-Fi" 格外不安，
        # 像软件在偷偷改他的设置——说清是因为网线也没网了，才能安心。
        notify "SmartRoute" "网线上不了网，已自动打开 Wi-Fi 保持联网"
    fi

    # 【Wi-Fi 自动故障转移】Wi-Fi 上不了网、以太网也没外网时，自动换个能上网的 Wi-Fi
    wifi_failover_if_needed "$wifi_ok" "$eth_ok" "$wifi_res"

    # 期望的首选设备
    want=""
    case "$MODE" in
        # ethernet / wifi 是"偏好"，不是"这条不通就断网"。
        # 以前写成单行 &&，偏好设备不可用时 want 留空 → 下面
        # `if [ -n "$want" ]` 不成立 → 一次切换都不做，机器继续挂在
        # 已经上不了网的那条线上。实测场景：Wi-Fi 关联正常但没外网
        # （认证门户/运营商故障），macOS 不会自己挪默认路由，于是
        # 有线明明是好的，网络却是死的。
        # speed / latency 两个模式本来就有 elif 兜底（见下），
        # 这两个没有——同一套逻辑漏了两种模式，补上。
        ethernet)
            if [ "$eth_ok" -eq 1 ] && [ -n "$ACTIVE_ETH_DEV" ]; then
                want="$ACTIVE_ETH_DEV"
            elif [ "$wifi_ok" -eq 1 ] && [ -n "$ACTIVE_WIFI_DEV" ]; then
                want="$ACTIVE_WIFI_DEV"
                log "有线优先但有线不可用，回退到 Wi-Fi（可用性优先于偏好）"
            fi
            ;;
        wifi)
            if [ "$wifi_ok" -eq 1 ] && [ -n "$ACTIVE_WIFI_DEV" ]; then
                want="$ACTIVE_WIFI_DEV"
            elif [ "$eth_ok" -eq 1 ] && [ -n "$ACTIVE_ETH_DEV" ]; then
                want="$ACTIVE_ETH_DEV"
                log "Wi-Fi 优先但 Wi-Fi 不可用，回退到有线（可用性优先于偏好）"
            fi
            ;;
        speed)
            # 网速优先：实测吞吐大的赢。两个都上不了网时交给可用性逻辑兜底
            if [ "$eth_ok" -eq 1 ] && [ "$wifi_ok" -eq 1 ] \
               && [ -n "$ACTIVE_ETH_DEV" ] && [ -n "$ACTIVE_WIFI_DEV" ]; then
                # 【变慢预警】吞吐缓存还新鲜，但当前线路延迟已经明显高于另一条时，
                # 提前重测一次吞吐，不要等 SPEED_RECHECK（默认 300 秒）到期。
                # 没有这一步，线路劣化要最多 5 分钟才被发现——用户体感是
                # "变慢了半天也不换"。
                # 延迟探测只要几个包（约 1 秒），比每次都真下载便宜得多，
                # 所以拿它当廉价的早期信号是划算的。
                local _force=""
                if _metric_fresh "speed_$cur" "$SPEED_RECHECK"; then
                    ensure_latency "$ACTIVE_ETH_DEV" "$(svc_router "$ACTIVE_ETH_SVC")" \
                                   "$ACTIVE_WIFI_DEV" "$(svc_router "$ACTIVE_WIFI_SVC")"
                    local _oth_dev _lc _lo
                    _oth_dev="$ACTIVE_WIFI_DEV"
                    [ "$cur" = "$ACTIVE_WIFI_DEV" ] && _oth_dev="$ACTIVE_ETH_DEV"
                    _lc="$(_metric_val "lat_$cur")"
                    _lo="$(_metric_val "lat_$_oth_dev")"
                    # 两边都测得出来才比；任一边缺数据就按缓存走，不猜。
                    # 用 awk 比而不是 shell 整数：延迟是小数（14.3），
                    # 自己转整数要处理补齐位数、八进制（08）一堆坑，
                    # 而 pick_fastest 本来就用 awk，统一做法更不容易错。
                    if [ -n "$_lc" ] && [ -n "$_lo" ] \
                       && awk -v a="$_lc" -v b="$_lo" -v r="$LATENCY_DEGRADE_RATIO" \
                              'BEGIN{ exit !(a+0 > b+0 * r) }'; then
                        log "变慢预警: ${cur} 延迟 ${_lc}ms 超过 ${_oth_dev} 的 ${_lo}ms 的 ${LATENCY_DEGRADE_RATIO} 倍，提前重测吞吐"
                        _force=1
                    fi
                fi
                ensure_throughput "$ACTIVE_ETH_DEV" "$ACTIVE_WIFI_DEV" "$_force"
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
        *)
            # auto（默认模式）原来只看"哪个能上网"，有线永远赢。
            #
            # 这在两条线差不多快时没问题，但差很多时就是灾难：
            # 本机实测 en0 封顶 92 Mbps（100baseTX），en1 能跑 270 Mbps（Wi-Fi 6
            # 160MHz）。用户开着默认配置，于是**永远被钉在慢 3 倍的那条线上**，
            # 而 status 显示一切正常——这正是"网络还是不好"的来源。
            #
            # 单连接测速时代两个数只差 4%（78.9 vs 82.3），加了也是噪声；
            # 多连接测速修好后差值稳定在 2.6-3.3 倍，这时候再不加就说不过去了。
            #
            # 做法：两边都可用时，用实测吞吐当 tiebreaker；测不出来就退回原行为
            # （有线优先）。不改变 auto 的可用性语义——某条线不通时照样转移。
            if [ "$eth_ok" -eq 1 ] && [ "$wifi_ok" -eq 1 ] \
               && [ -n "$ACTIVE_ETH_DEV" ] && [ -n "$ACTIVE_WIFI_DEV" ]; then
                # 复用缓存（SPEED_RECHECK 秒内不真下载），不拖慢轮询。
                # force 传空：auto 不该为了选路而强制下载，那会把 20 秒的
                # 轮询周期拉长好几秒。
                ensure_throughput "$ACTIVE_ETH_DEV" "$ACTIVE_WIFI_DEV"
                local _ae _aw _apick
                _ae="$(_metric_val "speed_$ACTIVE_ETH_DEV")"
                _aw="$(_metric_val "speed_$ACTIVE_WIFI_DEV")"
                _apick="$(pick_by_speed "$ACTIVE_ETH_DEV" "$_ae" "$ACTIVE_WIFI_DEV" "$_aw")"
                # ⚠️ 空值的含义是"任一边没测到"，不只是"两边都没测到"。
                # pick_by_speed 已改成一方缺数据就整体弃权——因为一方是 0
                # 表示没测到（探测超时/源不可用/刚装上前两轮为空），
                # 不表示另一方更快。据此切走会把用户从一条可能完全正常的
                # 线上赶走，而依据根本不存在。
                # 弃权后保持现状；线真坏了由 probe_dev 的可用性探测兜底切走，
                # 两条机制互补，不会卡住。代价是这一轮不按速度选路，
                # 而下一次 ensure_throughput 最多等 SPEED_RECHECK（默认 300 秒）。
                case "$_apick" in
                    "")   want="" ;;      # 任一边没测到 → 保持现状，不猜
                    tie)  want="$cur" ;;  # 差距不够大，别折腾
                    *)    want="$_apick" ;;
                esac
                # 只在真的选了更快的那条时才说话。tie/测不出来时安静，
                # 否则每轮都刷一条日志，用户看不过来。
                if [ -n "$_apick" ] && [ "$_apick" != "tie" ]; then
                    log "自动选路: eth=$(fmt_bps "${_ae:-0}") wifi=$(fmt_bps "${_aw:-0}") -> ${_apick}"
                fi
            elif [ "$eth_ok" -eq 1 ] && [ -n "$ACTIVE_ETH_DEV" ]; then
                want="$ACTIVE_ETH_DEV"
            elif [ "$wifi_ok" -eq 1 ] && [ -n "$ACTIVE_WIFI_DEV" ]; then
                want="$ACTIVE_WIFI_DEV"
            fi ;;
    esac

    echo "$(ts) eth=${ACTIVE_ETH_DEV:-无}($eth_res) wifi=${ACTIVE_WIFI_DEV:-无}($wifi_res) default=${cur:-无} want=${want:-保持} mode=$MODE"

    # now 在 if 之前取一次，两个分支共用同一个时间基准。
    # 只在 if 分支里赋值是不够的：want==cur（本轮无需切换）时走 elif，
    # 那时 now 还是空，算术里按 0 算，抖动计数的清零永远不触发——
    # 而那正是修 flap 振荡的唯一路径。
    now=$(date +%s)
    if [ -n "$want" ] && [ "$want" != "$cur" ]; then
        # 冷却期，防止在两个接口间反复横跳
        local last
        last="$(state_get last_switch)"
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        if [ $((now - last)) -lt "$COOLDOWN" ]; then
            log "冷却期中（距上次切换 $((now - last))s < ${COOLDOWN}s），跳过本次切换"
            return 0
        fi
        # 【 futile 抗争退避】系统已经第 FLAP_BACKOFF_AT 次把默认路由判回去了，
        # 就别再抢。实测这台机器：macOS 每几分钟把默认路由判回 en0，工具切回
        # en1，累计 105 次。每次切换都要跑 networksetup -ordernetworkservices
        # （重配所有网络服务）+ sleep 2，随后又被判回去。用户体感是
        # "网络被这工具卡住了"——这时候继续抢比不抢更糟，必须停手。
        #
        # 但**只在两条线都健康时退避**。偏好之争（都想上，只是选哪个）可以等；
        # 真的有一条线死了必须立刻切，否则就是拿用户的断网换自己的清静。
        # 这个区分是这条逻辑能存在的前提。
        # 退避用独立的时间戳 flap_quiet_until，不用 last_switch。
        # 后者同时被冷却期、flap 累加、flap 清零三处使用，混在一起会互相
        # 干扰：清零逻辑会在退避途中把 flap_count 清掉，退避条件随之失效，
        # 于是重新开始抢——退避等于没做。
        local _fn _quiet
        _fn="$(state_get flap_count)"
        [[ "$_fn" =~ ^[0-9]+$ ]] || _fn=0
        _quiet="$(state_get flap_quiet_until)"
        [[ "$_quiet" =~ ^[0-9]+$ ]] || _quiet=0
        if [ "$_fn" -ge "$FLAP_BACKOFF_AT" ] \
           && [ "$eth_res" = "ok" ] && [ "$wifi_res" = "ok" ] \
           && [ "$now" -lt "$_quiet" ]; then
            # 只在进入退避时说一次，不要每轮刷屏
            if [ "$(state_get flap_backoff)" != "1" ]; then
                state_set flap_backoff 1
                state_set flap_quiet_until $((now + FLAP_BACKOFF))
                log "选路退避：默认路由已被系统改回累计 $_fn 次，暂停切换 ${FLAP_BACKOFF}s（两条线都正常，属偏好之争，先让网络稳下来）"
                log "  根因：两个接口同网段/同网关时，系统会反复把默认路由判回同一个接口"
                log "  想彻底解决：让两个口走不同网段，或用 smartroute balance on 做双网并发"
                notify "SmartRoute 已暂停自动切换" "默认路由已被系统改回累计 ${_fn} 次。两条线都正常，继续抢只会让网络更卡，已暂停 ${FLAP_BACKOFF} 秒。若网线和 Wi-Fi 接同一台路由器，请看状态页的说明。"
            fi
            return 0
        fi
        if [ "$(state_get flap_backoff)" = "1" ]; then
            # 退避到期：给一次重新尝试的机会，并把计数清零重新累计。
            # 不清零的话下一轮会立刻再进退避，等于永久放弃——用户若真把
            # 网络改好了（两个口不同网段），工具永远发现不了。
            state_set flap_backoff 0
            state_set flap_count 0
            state_set flap_quiet_until 0
            log "选路退避结束，重新尝试自动切换"
        fi
        do_switch "$want" "$cur" "$eth_res" "$wifi_res" "$se" "$sw"
    elif [ -n "$(state_get flap_count)" ] && [ "$(state_get flap_count)" != "0" ]; then
        # 问题解决后必须把 flap 计数清掉。
        #
        # 否则：用户按提示改了局域网网段、系统不再反复判回以太网了，
        # 状态页却永远挂着"macOS 已 51 次把默认路由改回以太网"。
        # 一个永不消失的假警报比没有警报更糟——它会让人怀疑工具在说谎，
        # 然后不再看任何提示。
        #
        # 但"这一轮不需要切换"**不能**作为"没在抖"的证据。
        #
        # 实测踩过：MODE=wifi 时 daemon 把默认路由切到 en1，下一轮
        # cur==want 走进这个分支清零；紧接着 macOS 又判回 en0，再下一轮
        # do_switch 把 flap_n 从 0 加到 1。于是 flap_count 永远在 0 和 1
        # 之间振荡，永远到不了 3，警报永远不响。真实症状是
        # switch_count 已经 105 次，而 flap_count 始终是空的——
        # 界面一片安静，用户完全不知道系统在反复改路由。
        #
        # 正确的 staleness 判据和 do_switch 里保持同一个：距上次切换超过
        # 抖动窗口（1800s）才算真的久了。真抖时每次间隔都远小于窗口，
        # 计数累加上去、警报会响；真修好之后半小时没有切换，计数自动清掉、
        # 警报会消失。两条路径用同一个时间尺度，才不会一边清零一边累加。
        _last="$(state_get last_switch)"
        [[ "$_last" =~ ^[0-9]+$ ]] || _last=0
        # 退避途中不能清 flap_count：退避条件正是 flap_count >= 门槛，
        # 一清就等于提前解除退避，重新开始每 20 秒抢一次路由。
        # 退避自己会在到期时清零（见上面的退避退出分支）。
        if [ $((now - _last)) -gt 1800 ] && [ "$(state_get flap_backoff)" != "1" ]; then
            state_set flap_count 0
            state_set flap_target ""
            log "默认路由已稳定，清除选路不稳定计数"
        fi
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
    # 偏好接口不可用、已经回退到另一条线时，必须说出来。
    # 用户选"Wi-Fi 优先"是偏好，不是"Wi-Fi 不通就断网"；真回退到有线时他
    # 有权知道——否则他会以为工具没干活，或者更糟：以为自己的 Wi-Fi 是好的。
    # 状态页是默认落地页，结论放这里才看得见。
    case "$MODE" in
        ethernet)
            [ -n "$cur" ] && [ -n "$ACTIVE_ETH_DEV" ] && [ "$cur" != "$ACTIVE_ETH_DEV" ] && {
                echo "⚠️  偏好有线，但当前走在 ${cur}（有线不可用，已回退）"
                echo "    有线恢复后会自动切回；不想等就 smartroute set MODE speed"
            }
            ;;
        wifi)
            [ -n "$cur" ] && [ -n "$ACTIVE_WIFI_DEV" ] && [ "$cur" != "$ACTIVE_WIFI_DEV" ] && {
                echo "⚠️  偏好 Wi-Fi，但当前走在 ${cur}（Wi-Fi 不可用，已回退）"
                echo "    Wi-Fi 恢复后会自动切回；不想等就 smartroute set MODE speed"
            }
            ;;
    esac
    # 机器可读的关键事实。App 需要据此在**状态页**就给出警告，而不只是
    # 在双网并发页（原先后者才会解析 balance status 才知道同网关）。
    # 用户抱怨"故障转移没效果、双网并发也没效果"时，他正在看的是状态页——
    # 结论必须出现在他眼前那一页，否则等于没说。
    if [ -n "$eth_gw" ] && [ "$eth_gw" = "$wifi_gw" ]; then
        echo "same_gateway  : $eth_gw"
    fi
    echo "判定结果     : eth_ok=$(state_get eth_ok) wifi_ok=$(state_get wifi_ok) streak_eth=$(state_get streak_eth) streak_wifi=$(state_get streak_wifi)"
    echo "最近切换     : $(human_ts "$(state_get last_switch)")（累计 $(state_get switch_count) 次）"
    # 链路与实测：解释"为什么走了这条"。
    # 注意：以前这里写"Wi-Fi 读不到链路速率"，其实不对——读不到的是
    # networksetup -getMedia（只回 autoselect），system_profiler 里有真实的
    # Transmit Rate 和噪声底。用户最初的疑问"网线 100M、Wi-Fi 标称 1000M，
    # 为什么不走 Wi-Fi"，答案就在这里。
    if [ -n "$ACTIVE_ETH_DEV" ]; then
        local _em _es _emax
        _em="$(link_media "$ACTIVE_ETH_DEV" 2>/dev/null)"
        _es="$(link_speed_mbps "$_em")"
        _emax="$(nic_max_speed "$ACTIVE_ETH_DEV")"
        echo "以太网链路   : ${_em:-未知}"
        # 链路速率远低于网卡能力时，必须说清楚"这不是软件问题"。
        # 用户看到"有线 100M、Wi-Fi 432M"就会问为什么不能相加成 532M——
        # 真相是网卡能跑 2.5G，链路只谈到 100M，差的是网线或路由器端口。
        # 修好它一条有线就能跑满千兆宽带，比两条线做软件聚合更强。
        # 含糊其辞的后果是用户一直跟软件较劲，还反复重装。
        # 阈值取 1000 而不是"任何差距"：宽带通常就是千兆，1000baseT 已经跑满，
        # 此时报「网卡支持 2500M」是噪音——换了线也快不了，上游封死了。
        # 真正值得报警的是"硬件够却够不到千兆"（100baseTX 只用 2 对线，
        # 线序坏一对就掉下来），那种情况换根线立刻有 10 倍收益。
        if [ -n "$_es" ] && [ -n "$_emax" ] && [ "$_es" -lt 1000 ] && [ "$_emax" -ge 1000 ]; then
            echo "⚠️  以太网只协商到 ${_es}M，而网卡支持 ${_emax}M"
            echo "    这不是本工具的限制，是网线或路由器端口："
            echo "    • 换一根 Cat5e 以上网线（100baseTX 只需 2 对线通，1000baseT 要 4 对全通）"
            echo "    • 或把网线插到路由器的千兆口"
            echo "    修好之后：一条有线即可跑满千兆宽带，强于任何两条线的软件聚合"
        fi
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
        # 只打数字不够——用户看到"当前走有线"时真正想知道的是**为什么**。
        # auto 和 speed 两个模式都按 pick_by_speed 选路，把它判定的结论
        # 原样打出来，用户就不必反复问"为什么不走快的那条"。
        #
        # 三种情况都要说人话：
        #   tie  → "差不多，不折腾"（否则以为工具没在做决定）
        #   空   → "还没测出数据"（刚装上前两轮为空是正常的，不是故障）
        #   具体 → 当前是不是就是快的那条；不是的话说明受冷却期约束
        local _why
        _why="$(pick_by_speed "${ACTIVE_ETH_DEV:-}" "${_es:-0}" "${ACTIVE_WIFI_DEV:-}" "${_ws:-0}")"
        case "$_why" in
            "")  echo "选路依据     : 还没测出可用的吞吐数据，按可用性选路" ;;
            tie) echo "选路依据     : 两条线速度差不多（差距不足 ${SPEED_SWITCH_RATIO}%），不来回切换" ;;
            *)   if [ -n "$cur" ] && [ "$cur" = "$_why" ]; then
                     echo "选路依据     : 当前 ${_why} 就是实测较快的那条"
                 else
                     echo "选路依据     : 实测较快的是 ${_why}，当前走 ${cur:-未知}（切换受冷却期约束）"
                 fi ;;
        esac
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
    # test 会探测两个接口，同样动主机路由，也要和守护进程互斥
    acquire_lock_wait 10 || die "另一个 smartroute 操作正在进行（守护进程刚跑过一轮），请稍候再试"
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
    # 三种写法都要认，尤其是第二种——那是用户最自然的写法：
    #   smartroute set wifi
    #   smartroute set MODE wifi        ← KEY VALUE 两个参数
    #   smartroute set MODE=wifi
    # 以前只认第一和第三种，于是 `set MODE wifi` 落到下面的 *) 报
    # "无法识别: MODE"——而 MODE 明明是个合法配置键。用户看到这句只会
    # 更困惑：到底是模式名写错了，还是这个键不存在？
    # 判定"长得像配置键"用全大写+下划线，不会和模式名（全小写）混淆。
    if [ -n "${2:-}" ] && printf '%s' "$1" | grep -qE '^[A-Z][A-Z0-9_]*$'; then
        kv="$1=$2"
    fi
    if [ -z "$kv" ]; then
        echo "用法: smartroute set auto|ethernet|wifi|speed|latency"
        echo "  或: smartroute set KEY VALUE      （KEY 见 smartroute config）"
        echo "  或: smartroute set KEY=VALUE"
        exit 1
    fi
    case "$kv" in
        auto)          key="MODE"; val="auto" ;;
        ethernet|eth)  key="MODE"; val="ethernet" ;;
        wifi|wlan)     key="MODE"; val="wifi" ;;
        speed|fast)    key="MODE"; val="speed" ;;
        latency|lowdelay) key="MODE"; val="latency" ;;
        *=*)           key="${kv%%=*}"; val="${kv#*=}" ;;
        *) echo "无法识别: $kv"
           echo "用法: smartroute set auto|ethernet|wifi|speed|latency"
           echo "  或: smartroute set KEY VALUE   （KEY 见 smartroute config）"
           exit 1 ;;
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
    local key="$1" val="$2" target="$3" cu tmp _rc
    if [ -f "$target" ]; then
        # 路径一：同目录临时文件 + 原子替换（最稳，但 /Users/Shared 带 sticky 位时
        # 非属主 mv 会 EPERM）
        #
        # grep -v 的退出码必须显式放行 1。grep 返回 1 的语义是"没有行被选中"，
        # 不是出错。空配置文件（0 字节，或被 truncate 过）走这支时，grep -v
        # 输出空、返回 1，于是整个 && 链短路，**写入被静默判成失败**——用户看到
        # "写入 xxx 失败"，而文件其实完好、权限也没问题，完全无法排查。
        # 只有退出码 >=2 才是真的 grep 出错（文件不存在/不可读）。
        tmp="$3.tmp.$$"
        _rc=0
        grep -v "^$key=" "$target" > "$tmp" 2>/dev/null || _rc=$?
        if [ "$_rc" -le 1 ] && \
           printf '%s=%s\n' "$key" "$val" >> "$tmp" 2>/dev/null && \
           mv "$tmp" "$target" 2>/dev/null; then
            :
        else
            rm -f "$tmp" 2>/dev/null
            # 路径二：退化成原地覆写（目录不可写但文件本身可写时用）
            tmp="${TMPDIR:-/tmp}/smartroute.conf.$$"
            _rc=0
            grep -v "^$key=" "$target" > "$tmp" 2>/dev/null || _rc=$?
            if [ "$_rc" -le 1 ] && \
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
            # 不要建议"修改路由器 LAN 网段"。对用户来说那等于"去改硬件/
            # 网络配置"——他明确说过做不到、也不是他要解决的问题。
            # 他要的是在这个网络现状下把并发做出来。
            # 同网段真正的影响是：内核按路由表选源 IP，同子网只会用默认路由
            # 那个接口的 IP，所以 pf route-to 改了出口却改不了源地址，
            # 回程流量仍从原接口回来。这个已经在 write_pf_rules 里用
            # nat on ... -> ($ext) 解决了，剩下的是聚合带宽受上游限制。
            advice+=("同网段已处理：分流规则带 nat on ... -> (\$ext) 强制按出口改源地址，回程才不会走错接口")
            # 同网段通常意味着同一个网关、同一台路由器——那"双网并发"就没有
            # 第二条 WAN 可分。这条建议是可操作的（关掉开关就行），
            # 而"改路由器网段"对大多数人做不到，所以必须补上。
            if eth_wifi_same_gateway; then
                echo "    ${C_WARN}⚠️  而且两者网关相同（$(svc_router "${ACTIVE_ETH_SVC:-}" 2>/dev/null)），是同一台路由器${C_RST}"
                echo "        → 双网并发（BALANCE=1）不会有任何带宽收益，反而会把一半连接赶到更慢的接口"
                # 陈述事实，不 prescribe 关掉。
                # 用户明确要的就是并发（"两个网络一起跑一个数据"），
                # 每次 doctor 都劝他关掉，既不听诉求，也没说清什么还有效。
                # 而且原来的第二条建议是**错的**：同网关下用
                # `smartroute fetch <URL> -n 4` 多连接下载仍能超过
                # 单连接速度——瓶颈常常在单条 TCP 的拥塞控制/窗口，
                # 不在聚合链路带宽。挑一个更快的接口反而拿不到这部分。
                advice+=("同网关下并发不增加聚合带宽（上游是一条），但多连接/多应用仍可能更快：")
                advice+=("  下载大文件用 smartroute fetch <URL> -n 4，让多个连接分摊到两个接口")
                advice+=("  若只想让故障时另一条线立刻接上，保持开启即可，代价是慢接口会分到一部分连接")
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
    # 五个模式都要列。原来只写三个，用户选了"网速优先"后看体检报告，
    # 会以为自己的设置没生效——又是"界面说的和实际不一样"。
    echo "    选路模式: ${MODE}（auto=谁有外网走谁 / ethernet=强制有线 / wifi=强制无线 / speed=网速优先 / latency=延时优先）"

    echo
    echo "[7] smartroute 运行状态"
    echo "    eth_ok=$(state_get eth_ok) wifi_ok=$(state_get wifi_ok) streak_eth=$(state_get streak_eth) streak_wifi=$(state_get streak_wifi)"
    echo "    最近切换: $(human_ts "$(state_get last_switch)")，累计 $(state_get switch_count) 次"
    # 判断守护进程活着，不能只看 pgrep。这个 plist 用的是 StartInterval=20，
    # 进程只在每次运行的瞬间存在（约 1~2 秒），pgrep 命中率只有一成左右。
    # 而 launchctl print system/... 要 root——App 里的体检页是**不带 sudo** 调的，
    # 终端里也常有人忘了加 sudo。两条都不满足就报"未检测到"，
    # 于是十次有八次误报，还劝人家重装一遍。
    #
    # 改用日志新鲜度：cmd_watch 每轮结束都往 stdout 打一行，plist 把它重定向到
    # /var/log/smartroute.out，所以这个文件的 mtime 就是守护进程的心跳，
    # 而且普通用户就能 stat 到。pgrep 降级为佐证，launchctl print 仅在有 root 时兜底。
    local dstate="stopped" dage="?"
    if [ -f /var/log/smartroute.out ]; then
        local now mt
        now="$(date +%s)"
        mt="$(stat -f%m /var/log/smartroute.out 2>/dev/null || echo 0)"
        dage=$(( now - mt ))
        if [ "$dage" -lt 90 ]; then
            dstate="running"
        elif [ "$dage" -lt 300 ]; then
            dstate="waiting"
        fi
    fi
    if [ "$dstate" = "stopped" ] && pgrep -f 'smartroute watch' >/dev/null 2>&1; then
        dstate="running"; dage="<1"
    fi
    if [ "$dstate" = "stopped" ] && [ "$(id -u)" -eq 0 ] \
       && launchctl print system/com.user.smartroute >/dev/null 2>&1; then
        dstate="running"; dage="?"
    fi
    case "$dstate" in
        running)
            echo "    守护进程: 运行中 ${C_OK}✓${C_RST}（心跳 ${dage} 秒前）"
            ;;
        waiting)
            # 刚唤醒或刚装完时日志会短暂过期。说清是在等，别让人以为坏了——
            # 误报的代价是有人会去重装一遍。
            echo "    守护进程: ${C_WARN}可能刚唤醒或刚安装，等待下一次检测（上次心跳 ${dage} 秒前）${C_RST}"
            ;;
        stopped)
            echo "    守护进程: ${C_ERR}未检测到（未安装或已停止）${C_RST}（上次心跳 ${dage} 秒前）"
            # 不能写死 ~/Pictures/smartroute——用户可能从别处安装
            # （下载 zip 解压到 Downloads、clone 到别处）。照着一条
            # 不存在的路径执行只会得到 "No such file or directory"，
            # 而真正要做的只是"在安装目录里跑 install.sh"。
            # $0 是用户实际调用的路径，从它推目录才对。
            local _d
            _d="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
            advice+=("守护进程未运行：cd ${_d:-<smartroute 安装目录>} && sudo bash install.sh")
            ;;
    esac

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
    local want="" keep="" applied line cidr dev gw entry ifs
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
               # 删除失败不能静默。以前只在本轮成功时打日志，失败什么都不会说，
               # 而这条 entry 随后被从 applied_routes 里去掉——于是孤儿路由
               # （指向已删除接口或已停用的规则）留在系统路由表里，
               # 之后 balance off / 改规则时再也不会有人尝试删它。
               # 至少要留下证据，并把它保留在 applied_routes 里下次再试。
               if route_del_net "$cidr" "$dev"; then
                   log "分流规则: 删除路由 $cidr via $dev"
               else
                   log "分流规则: 删除路由 $cidr via $dev 失败（该路由可能已不在，保留记录下次重试）"
                   keep="${keep}${entry};"
               fi ;;
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

    # 删除失败的 entry 要留在记录里（见上面删除循环），否则下一轮不会再有人
    # 尝试删它，孤儿路由就永久留在系统路由表里。keep 里的项都不在 want 中
    # （只在"规则里没有"时才可能进 keep），所以拼起来不会重复。
    state_set applied_routes "$want$keep"
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
    local sub="${1:-list}" _rc
    # _rc 必须在这里声明：add/del 两个分支都靠它接 grep -v 的退出码，
    # 不声明就会漏到全局作用域，被别的函数读写造成难以定位的串味。
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
            # 同 rule del：空规则文件时 grep -v 返回 1，不能直接用 && 串
            _rc=0
            grep -v "^$cidr[[:space:]]" "$RULES_FILE" > "$RULES_FILE.tmp" 2>/dev/null || _rc=$?
            [ "$_rc" -le 1 ] && mv "$RULES_FILE.tmp" "$RULES_FILE" 2>/dev/null
            [ "$_rc" -gt 1 ] && { rm -f "$RULES_FILE.tmp"; die "读取 $RULES_FILE 失败"; }
            printf '%s %s\n' "$cidr" "$dev" >> "$RULES_FILE" || die "写入 $RULES_FILE 失败"
            echo "已添加规则: $cidr -> $dev"
            echo "守护进程将在 ≤20 秒内应用；可 sudo smartroute watch 立即应用"
            ;;
        del|rm)
            local cidr="$2"
            [ -n "$cidr" ] || die "用法: smartroute rule del <CIDR>"
            [ -f "$RULES_FILE" ] || die "规则文件不存在（${RULES_FILE}）"
            # grep -v 返回 1 是"没有行被选中"（删的是最后一条规则时就会这样），
            # 不是出错。用 && 串起来会让删除最后一条规则时 mv 不执行，
            # 而下一行照样打印"已删除规则"——规则还在，却告诉用户删好了。
            _rc=0
            grep -v "^$cidr[[:space:]]" "$RULES_FILE" > "$RULES_FILE.tmp" 2>/dev/null || _rc=$?
            if [ "$_rc" -le 1 ]; then
                mv "$RULES_FILE.tmp" "$RULES_FILE" 2>/dev/null || die "写入 $RULES_FILE 失败"
            else
                rm -f "$RULES_FILE.tmp" 2>/dev/null
                die "读取 $RULES_FILE 失败"
            fi
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

# ---------------- 多连接下载：让两条线一起扛一个文件 ----------------
#
# 为什么需要它：用户问"两个网络一起跑一个数据"。IP 路由层面做不到——
# pf 按连接（状态）选路，一个 TCP 连接从头到尾只用一条线；一条流跨两条线
# 需要 MPTCP，macOS 不支持。这是硬限制，不是实现力度问题。
#
# 但"一个文件"可以拆。HTTP Range 请求让同一个文件被切成多段，每段是一条
# 独立的 TCP 连接。配合 pf 轮询分流，这些连接会分摊到两个接口上，
# 下载端按顺序拼回原文件——用户看到的就是"一个下载用满了两条线"。
#
# 这是软件层面能达到的上限，且对单文件下载确实有效。
cmd_fetch() {   # $1=URL [-o 输出] [-n 连接数] [--no-balance-check]
    # 默认 4 是实测峰值（见下面连接数上限处的数据）。
    local url="" out="" n=4 check=1 a
    while [ $# -gt 0 ]; do
        case "$1" in
            # 两个必须校验的地方：
            #  1) 后面还有没有参数。没有时 bash 的 shift 2 失败且**不移位**，
            #     while 循环原地打转——无输出、CPU 打满、永远卡死。
            #  2) 参数值不能以 - 开头。否则 "-o --no-balance-check" 会把
            #     选项名当成文件名，真的建出一个叫 "--no-balance-check" 的文件；
            #     "-n --no-balance-check" 则报一句"连接数必须是正整数"，
            #     完全指不到真正的原因（漏写了值）。
            -o|--output)
                [ $# -ge 2 ] || die "-o/--output 需要一个参数（输出文件名）"
                case "$2" in -*) die "-o/--output 的参数不能以 - 开头: $2（是不是漏写了文件名？）" ;; esac
                out="$2"; shift 2 ;;
            -n|--conns)
                [ $# -ge 2 ] || die "-n/--conns 需要一个参数（连接数）"
                case "$2" in -*) die "-n/--conns 的参数不能以 - 开头: $2（是不是漏写了连接数？）" ;; esac
                n="$2"; shift 2 ;;
            --no-balance-check) check=0; shift ;;
            -h|--help)
                cat <<'USAGE'
用法: smartroute fetch <URL> [-o 输出文件] [-n 连接数]

  把一个下载拆成多个 TCP 连接，配合双网并发让两条线一起扛一个文件。

  HTTP 层用 Range 请求切段，每段一条独立连接；pf 轮询分流把这些连接
  分摊到两个接口；下载完按顺序拼回原文件。

  注意：这依赖服务端支持 Range。工具会真发一个 Range 请求探测，
  不支持时自动退化为单连接并说明原因。

  连接数：默认 4，上限 16。-n 给的是**上限**，不是一开始就起这么多。
 工具先起 2 条，之后每当下完的分片数达到阈值就加一条，直到 -n 的上限。
 服务端扛得住就自动加到上限，扛不住就停在低连接数——实测连接数超过
 峰值后吞吐单调下降（n=4 是 17.6 Mbps，n=16 掉到 8.0 Mbps，失败分片
 从 2 个涨到 11 个），所以让工具自己判断比一次起满更稳。

 前置条件: sudo smartroute balance on [round-robin|weighted]
  不开启也能跑，但所有连接会走同一条线，看不到叠加效果。

示例:
  smartroute fetch https://example.com/big.iso -o big.iso -n 4
USAGE
                return 0 ;;
            -*) die "未知选项: $1（用 --help 看用法）" ;;
            *)  [ -z "$url" ] && url="$1" || die "只接受一个 URL"; shift ;;
        esac
    done
    [ -n "$url" ] || die "用法: smartroute fetch <URL> [-o 输出] [-n 连接数]"
    case "$n" in ''|*[!0-9]*) die "连接数必须是正整数: $n" ;; esac
    [ "$n" -ge 1 ] || die "连接数至少为 1"
    # 上限 16，默认 4。这两个数字是**实测**定的，不是拍的。
    #
    # 实测（1GB 文件，OVH，两接口交替分片）：
    #     n=2   218MB  1 个分片失败   17.0 Mbps
    #     n=4   219MB  2 个分片失败   17.6 Mbps   ← 峰值
    #     n=8   178MB  4 个分片失败   14.3 Mbps
    #     n=16   97MB  11 个分片失败   8.0 Mbps
    # 失败分片数基本随 n 等比例增长，吞吐单调下降。原因是连接数一多，
    # 服务端开始限流/丢连接，而每条连接的 TCP 慢启动重新来过，反而更慢。
    #
    # 所以：
    #   · 默认从 8 降到 4 —— 原来的默认值已经落在衰减区
    #   · 上限从 64 降到 16 —— -n 16 实测是灾难（单独测 1GB 只下了 153MB
    #     就多个连接超时）。旧注释说"两条宽带走 8~24 就够"是想当然，
    #     与实测矛盾。
    #   · 另外有自适应扩连接（见下面的 _fetch_ramp）：真正需要更多连接时
    #     由工具自己判断，不需要用户猜。
    [ "$n" -le 16 ] || die "连接数上限 16（-n $n 太多了）。实测 n=16 已明显衰减，需要更多连接请用自适应扩连"

    command -v curl >/dev/null 2>&1 || die "系统缺少 curl"

    # 输出名：用户没给就从 URL 推
    if [ -z "$out" ]; then
        # 先剥 query 再剥 # 片段，顺序不能反。
    # 只剥 query 不剥 # 的后果：URL 带片段锚点（CDN 直链常见，形如
    # http://x/f.iso#sha=1）会存成一个名叫 "f.iso#sha=1" 的文件——
    # 扩展名变了，双击打不开，而且很难联想到是锚点导致的。
    # 反过来先剥 # 再剥 ? 也行，但两种都要剥。
    out="${url%%#*}"; out="${out%%\?*}"; out="${out##*/}"
    [ -n "$out" ] || out="download"
        [ -n "$out" ] || out="download.bin"
    fi

    # 没开 pf 分流就说清楚，否则用户看不到叠加会以为功能坏了。
    # ⚠️ 这段话以前写的是"要看到两条线叠加，先执行 balance on"——而下面
    # 紧接着就打"分片将分摊到 en0/en1（显式绑接口，不依赖 pf）"。
    # 两句话直接矛盾，而用户刚因为 pf 分流遇到过网络卡死。pf 是**另一条**
    # 路径，不是多连接下载的前提。
    if [ "$check" = "1" ] && [ ! -s "$PF_ANCHOR_FILE" ]; then
        cat >&2 <<MSG
提示：未启用 pf 分流（balance）。这不影响多连接下载——分片会按
      --interface 显式绑到各条线上，见下面"分片将分摊到"那一行。
      同网关拓扑下 pf 分流没有带宽收益，还有网络卡死风险，一般不用开。
MSG
    fi

    echo "探测 $url …"
    # 三个信息都要：支不支持 Range、文件多大、以及大小是否可信。
    #
    # 为什么不能只用一种办法（每种都在真实 CDN 上失败过）：
    #   · 普通 HEAD —— 有时压根不返回 Content-Length（HTTP/2 + 分块）
    #   · --range 0-0 —— 有的 CDN 返回 206 却不带 Content-Range，只有 1 字节
    #   · --range 999999999-（越界）—— 规范要求返回 416 + Content-Range: */N，
    #     且 body 为 0、不浪费流量。但实测同一 URL 它和 HEAD 会给出**不同**的
    #     大小（CDN 按请求返回不同压缩变体），信它就会切出错文件。
    #
    # 所以：HEAD 优先（对大多数服务器最准），越界探针兜底，
    # 最后由下载时的字节数校验做最终裁决——宁可失败也不产出错文件。
    local probe_hdr probe_code size="" cr_size="" head_size=""
    # --max-filesize 65536 必须加，否则探针本身可能等于白下一次整个文件。
    #
    # 实测（Cloudflare 测速端点 speed.cloudflare.com/__down?bytes=5000000）：
    #   探针耗时  2.73s
    #   下载本体  2.47s
    #   干净 curl 2.42s
    # 也就是说 fetch 比裸 curl 慢 2.4 倍，慢出来的时间几乎全在探针上。
    # 原因：规范要求越界 Range 返回 416 且 body 为 0，但这个端点是动态生成的，
    # 它先把 5MB 生成完才去看 Range——探针等于完整下一次。
    #
    # 加了 --max-filesize 后探针降到 0.77s（3.5 倍）。curl 在 Content-Length
    # 超过上限时根本不开始传输，直接返回 63，而**响应头已经拿到了**——
    # 我们只需要状态行和 Content-Range，两者都在 body 之前。
    #
    # 对规范服务器无影响：416 的 body 本来就是 0，不会触发上限。
    # 已用本地 stub 验证两种服务器（返回 416+Content-Range 的 / 返回 200 的）
    # 加与不加的判定结果完全一致。
    #
    # 注意判的是 $probe_hdr 非空而不是 curl 退出码：触发上限时退出码是 63，
    # 但头已经拿到，探针是成功的。
    probe_hdr="$(curl -sS -L -D - -o /dev/null --range 999999999- \
                 --max-filesize 65536 --max-time 20 "$url" 2>/dev/null)"
    [ -n "$probe_hdr" ] || die "取不到响应（网络不通或 URL 无效）"
    # 必须取**最后一条**状态行，不是第一条。
    # curl -L -D - 会把重定向链上每一跳的响应头都打出来，NR==1 拿到的是
    # 第一跳的 302，而不是最终响应的 416/206。
    # 实测：本地 302→416 服务，首行是 "HTTP/1.0 302 Found"，末行才是
    # "HTTP/1.0 416 Requested Range Not Satisfiable"。
    # 后果曾是：所有会跳转的 URL（github release、bit.ly、绝大多数 CDN 直链）
    # 都被判成"服务端不支持 Range"，双网叠加静默退化成单连接，
    # 还提示用户"换一个支持 Range 的源"——一个自信的错判。
    probe_code="$(printf '%s\n' "$probe_hdr" | awk '/^HTTP\//{c=$2} END{print c+0}')"
    # Content-Range: bytes */31402 —— 斜杠后就是总大小。
    # 取冒号之后的全部内容，不能用 $2：值形如 "bytes */31402"，
    # $2 是单位 "bytes"、$3 才是 "*/31402"。用 $2 会永远拿不到大小，
    # 于是每次都退化成单连接，表面上只是"取不到总大小"，极难查。
    # 顺带去掉行尾 CR（curl -D - 输出 CRLF）。
    cr_size="$(printf '%s\n' "$probe_hdr" | awk '
        tolower($1)=="content-range:" {
            line=$0
            sub(/^[^:]*:[[:space:]]*/,"",line)
            sub(/\r$/,"",line)
            n=split(line,a,"/")
            if (a[n]+0 > 0) v=a[n]
        }
        END{print v+0}')"

    # 支持 Range 的判定：416（规范行为）或 206（把越界范围截断到文件内）
    local range_ok=0
    if [ "$probe_code" = "416" ] || [ "$probe_code" = "206" ]; then range_ok=1; fi

    # HEAD 挪到这里：只有确定要切段（需要总大小）时才做。
    # 以前无条件先做，但不支持 Range 的那条分支直接 curl -o 下载，
    # 压根不读 $head_size 的值，那一次 HEAD（实测约 0.6s，含建连 + TLS）
    # 是纯浪费，而且偏偏浪费在最该快的路径上。
    local head_hdr head_size=""
    if [ "$range_ok" = "1" ]; then
        head_hdr="$(curl -sS -L -I --max-time 20 "$url" 2>/dev/null)"
        head_size="$(printf '%s\n' "$head_hdr" | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')"
    fi

    if [ "$range_ok" != "1" ]; then
        # HTTP 错误（4xx/5xx）不能一律说成"不支持 Range"。URL 写错、需要登录、
        # 文件不存在，都会被说成"换一个支持 Range 的源"，用户白换。
        case "$probe_code" in
            4*|5*)
                die "服务端返回 HTTP ${probe_code}，这个 URL 打不开。\
                    请先确认浏览器能访问它（可能是路径写错、需要鉴权、或文件已删除）。" ;;
        esac
        echo "服务端不支持 Range（越界范围返回 ${probe_code:-无响应}，期望 416），无法切段。"
        echo "这种情况只能单连接，两条线帮不上——换一个支持 Range 的源即可。"
        # --fail 必须加：否则 404/500 时 curl 返回 0，把错误页写进输出文件，
        # 还报一个"完成"——用户拿到一个内容是错误页的文件，比失败更糟。
        curl -L --fail --progress-bar -o "$out" "$url" || die "下载失败（HTTP 错误或网络中断）"
        echo "完成: $out"
        return 0
    fi

    # 大小：HEAD 优先，越界探针兜底
    size="$head_size"
    [ "$size" -gt 0 ] || size="$cr_size"
    if [ "$size" -le 0 ]; then
        echo "服务端支持 Range 但取不到总大小，改用单连接下载。"
        curl -L --fail --progress-bar -o "$out" "$url" || die "下载失败（HTTP 错误或网络中断）"
        echo "完成: $out"
        return 0
    fi
    # 两个来源都拿到却不一样：以 HEAD 为准，但要告知。
    # 这种 CDN 会按请求返回不同压缩变体，切段很可能拼出错文件——
    # 后面的字节数校验会拦住，这里先说清楚，免得用户以为是工具的 bug。
    if [ "$head_size" -gt 0 ] && [ "$cr_size" -gt 0 ] && [ "$head_size" != "$cr_size" ]; then
        echo "⚠️  服务端对同一文件报告了两个大小（HEAD ${head_size} / Range 探测 ${cr_size}）。"
        echo "    这类 CDN 会按请求返回不同变体，多连接下载可能拼不出原文件；"
        echo "    若下方校验失败，请改用单连接或换一个源。"
    fi

    # 连接数不能超过文件大小，否则有空段
    [ "$n" -gt "$size" ] && n="$size"

    # 措辞必须和实际行为一致：自适应扩连先起 2 条，之后才可能加到 n。
    # 以前这里直接写"$n 个连接并行下载"，用户会以为真有 n 条在跑，
    # 而活动监视器里只看到 2 条——软件撒谎比报错更糟。
    local _show_start="$n"
    [ "$_show_start" -gt 2 ] && _show_start=2
    if [ "$n" -gt "$_show_start" ]; then
        echo "大小 $(fmt_bytes "$size")，最多 $n 条连接（先起 $_show_start 条，按服务端表现逐步加）…"
    elif [ "$n" -eq 1 ]; then
        # n=1 时不走切分（见下面的快路径），说"并行下载"是自相矛盾
        echo "大小 $(fmt_bytes "$size")，单连接下载…"
    else
        echo "大小 $(fmt_bytes "$size")，$n 个连接并行下载…"
    fi

    # 抓基线字节数，下载完算增量，才能说出"每条线实际扛了多少"。
    # 在切段之前抓：抓晚了会把前面探测那几下算进去。
    local T rc=0 eth_before=0 wifi_before=0 t_start_s t_start_ns t_end_ns
    t_start_s="$(date +%s)"
    # 同时记秒和纳秒：纳秒用于精确算吞吐（小文件不会被低估），
    # 秒作为 date +%s%N 不可用时的退路。
    t_start_ns="$(date +%s%N)"
    case "$t_start_ns" in ''|*[!0-9]*) t_start_ns=0 ;; esac
    find_active
    [ -n "$ACTIVE_ETH_DEV" ]  && eth_before="$(_if_bytes "$ACTIVE_ETH_DEV")"
    [ -n "$ACTIVE_WIFI_DEV" ] && wifi_before="$(_if_bytes "$ACTIVE_WIFI_DEV")"
    case "$eth_before"  in ''|*[!0-9]*) eth_before=0 ;; esac
    case "$wifi_before" in ''|*[!0-9]*) wifi_before=0 ;; esac
    T="$(mktemp -d /tmp/smartroute_fetch.XXXXXX)" || die "建不了临时目录"
    # 无论成功失败都要清理，否则 /tmp 里堆一堆分片。
    #
    # 三个 trap 各自的职责（缺一个就会出问题）：
    #   RETURN      —— 函数正常返回时清理（语义见下）。
    #   INT/TERM/HUP—— 用户按 Ctrl-C 或进程被杀时清理。
    #   EXIT        —— die 走到 exit 时清理。**必须加**：die 调 exit，
    #                   而 exit 不触发 RETURN。以前只挂了前两类，
    #                   于是每条 die 路径都泄漏 /tmp/smartroute_fetch.XXXXXX
    #                   （10GB 文件坏一个分片就留下约 10GB，静默吃盘），
    #                   而错误信息还写着"临时文件已清理"——谎报。
    #
    # 关于 RETURN trap 的语义（实测确认，改动前先看这里）：
    # bash 的 RETURN trap 只在**设置它的那个函数**返回时触发，不会被它调用的
    # 函数继承——所以下面 _claim_chunk/_fetch_seg/_fetch_worker 返回时不会
    # 误删 ${T}，下载能正常跑完。tests/mock_fetch.sh 第 7 节用同样的函数结构
    # 锁定了这个行为。
    # ⚠️ 但这个结论依赖"内部函数在 trap 设置**之后**定义"。若把 _fetch_seg
    # 等助手函数移到 cmd_fetch 外面（变成先定义、后设 trap），RETURN trap
    # 就会在助手函数返回时触发、把 $T 删掉，下载全线失败。
    # 要外移助手函数的话，请把清理改成显式调用 + 只保留 INT/TERM/HUP 信号 trap。
    #
    # 中断处理：以前 Ctrl-C 后 trap 只删临时目录，父进程继续 wait 全部
    # worker（每段最长 600s），最后打一句"有分片下载失败（已重试 3 次）"
    # ——事实上零次重试、是用户主动取消，纯假消息。
    # 现在置 _fetch_aborted 标志让 worker 停下，wait 之后据此说"已取消"。
    trap '_fetch_aborted=1; rm -rf "$T"' INT TERM HUP
    trap 'rm -rf "$T"' RETURN EXIT

    # ── 工作队列，而不是固定切分 ──
    #
    # 固定切分（每连接一段）由**最慢的那一段**决定总时长。本机 100M 有线配
    # 432M Wi-Fi，-n 8 均分成 4/4：有线那 4 段是瓶颈，Wi-Fi 早早下完就闲着，
    # 聚合完全白做——总时间约等于"全文件走有线"的时间。
    #
    # 改成：把文件切成很多小片（目标 128 片以上，每片至少 1MB），起 n 个 worker，
    # 每个 worker 下完一片就回头认领下一片。快的线自然认领更多片，
    # 不需要知道两条线各多快，也不需要测速——这是自平衡的。
    #
    # 认领用 mkdir 做原子锁：同一片只有一个 worker 能建成目录，天然无锁。
    # 不用共享计数器 + flock——macOS 默认没有 flock，自己写锁又是轮询忙等。
    # ── -n 1：单连接就该是单连接，不要切分 ──
    #
    # 切了片是自找麻烦。100MB 文件会被切成 64 片、发 64 个 HTTP 请求：
    #   1) 按请求数限流的服务端直接 429——实测 proof.ovh.net 在我们累计下了
    #      约 2GB 之后就这样：浏览器单请求打得开，64 个请求全军覆没
    #   2) 任何一片失败就整体失败，失败面从 1 个变成 64 个
    #   3) 64 次 TLS 握手，纯开销
    # 单连接的吞吐上限由链路决定，切分一分都提不上去——想提速该加 -n，
    # 不是把一条连接拆成六十四条。
    if [ "$n" -eq 1 ]; then
        echo "单连接下载（不切分，一个 HTTP 请求）…"
        if curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 \
                --max-time 3600 -o "$out" "$url" 2>/dev/null; then
            local _n1got=0
            [ -f "$out" ] && _n1got="$(wc -c < "$out" | tr -d ' ')"
            echo "完成: ${out}（$(fmt_bytes "${_n1got:-0}")，1 连接）"
            # 单连接也必须报每条线扛了多少字节。少了这个，用户无法判断这一笔
            # 下载究竟走了哪条线，也就无法验证"切到 Wi-Fi"是否真的生效——
            # 而"证据"是这个工具唯一不该省的东西。
            local _n1eth=0 _n1wifi=0 _n1de _n1dw _n1all
            [ -n "$ACTIVE_ETH_DEV" ]  && _n1eth="$(_if_bytes "$ACTIVE_ETH_DEV")"
            [ -n "$ACTIVE_WIFI_DEV" ] && _n1wifi="$(_if_bytes "$ACTIVE_WIFI_DEV")"
            case "$_n1eth"  in ''|*[!0-9]*) _n1eth=0 ;; esac
            case "$_n1wifi" in ''|*[!0-9]*) _n1wifi=0 ;; esac
            _n1de=$(( _n1eth - eth_before ));  [ "$_n1de" -lt 0 ] && _n1de=0
            _n1dw=$(( _n1wifi - wifi_before )); [ "$_n1dw" -lt 0 ] && _n1dw=0
            _n1all=$(( _n1de + _n1dw ))
            echo "  实测分摊: 有线 +$(fmt_bytes "$_n1de")  Wi-Fi +$(fmt_bytes "$_n1dw")"
            [ "$_n1all" -gt $(( _n1got * 3 )) ] && [ "$_n1got" -gt 0 ] && {
                echo "  ⚠️  窗口内两个接口共 $(fmt_bytes "$_n1all")，远大于本次 $(fmt_bytes "$_n1got")，"
                echo "     说明期间还有其他程序在联网，上面的数字包含那部分流量。"
            }
            return 0
        fi
        # curl 自己不说状态码。补问一次，否则用户只知道"失败"，
        # 分不清该换源还是该降 -n——这两种的处理完全不同。
        local _n1code
        _n1code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -r 0-0 "$url" 2>/dev/null)"
        echo "下载失败（curl 退出码非 0${_n1code:+，服务端 HTTP ${_n1code}}）"
        echo "原因：URL 写错、文件不存在、需要登录/鉴权，或服务端临时故障。"
        echo "      先确认这个 URL 用浏览器能打开。Range 不兼容才该考虑降 -n。"
        return 1
    fi

    # ── 分片绑接口：让两条线一起扛一个文件 ──
    #
    # 为什么必须显式绑：_fetch_seg 的 curl 原来不带 --interface，所有分片都走
    # 默认路由。于是"双网并发"完全依赖 pf 把连接分摊到两个接口——而 pf 要么
    # 没加载（要 root），要么按 round-robin 盲分，会把一半连接赶到更慢的接口。
    #
    # 显式 --interface 不依赖 pf：每个分片自己选出口。本机两个接口同网段同网关，
    # 实测 curl --interface en0 / --interface en1 同时下载都正常（各 ~27-33 Mbps）。
    # 按片号轮询分配，不需要知道两条线各多快，也不需要测速——这是自平衡的。
    local _spread_devs="" _spread_n=0 _spread_ok=1 _d
    if [ -n "$ACTIVE_ETH_DEV" ] && [ -n "$ACTIVE_WIFI_DEV" ]; then
        _spread_devs="$ACTIVE_ETH_DEV $ACTIVE_WIFI_DEV"
    elif [ -n "$ACTIVE_ETH_DEV" ]; then
        _spread_devs="$ACTIVE_ETH_DEV"
    elif [ -n "$ACTIVE_WIFI_DEV" ]; then
        _spread_devs="$ACTIVE_WIFI_DEV"
    fi
    for _d in $_spread_devs; do _spread_n=$(( _spread_n + 1 )); done
    # 先验证 --interface 真的能用，不能用就退回不绑（走默认路由）。
    # 硬绑会让每个分片都失败，那比不绑糟得多。探测只取 1 字节，很便宜。
    if [ "$_spread_n" -gt 1 ]; then
        # 每个接口试 2 次。实测单次探测偶发失败过一次，而原来的写法是
        # "一次失败就整体放弃"——于是多接口分摊被一次网络抖动静默关掉，
        # 用户看到"分片走默认路由"，而他什么都没做错。
        # 这种静默降级比明说更难排查，所以保留 2 次重试。
        #
        # 但**两个接口必须并行探**，而且超时必须短。理由是一次实测事故：
        #   · 串行 + 8 秒超时：一个接口探测失败就要 8+1+8 = 17 秒，
        #     两个接口最坏 34 秒——而下载本身只要 1 秒。
        #   · 实测那次 fetch：裸 curl 稳定 0.52-0.63s，fetch 却出现 18s 的
        #     离群值，正好等于"一个接口探测两次超时（8+1+8=17s）+下载"。
        #     也就是说方差不是网络抖，是探测在最坏情况下把启动时间拉爆了。
        #   · 探测只取 1 字节，8 秒超时本来就过于宽松；4 秒足够，
        #     而且两个接口并行后最坏也只是 4+0.3+4 ≈ 8.3 秒，不再是 17 秒。
        local _pT; _pT="$(mktemp -d /tmp/smartroute_fprobe.XXXXXX)" || _pT=""
        if [ -n "$_pT" ]; then
            for _d in $_spread_devs; do
                (
                    _t=0
                    while [ "$_t" -lt 2 ]; do
                        if curl -s --interface "$_d" --max-time 4 -o /dev/null -r 0-0 \
                                "$url" 2>/dev/null; then
                            : > "$_pT/ok_$_d"; break
                        fi
                        _t=$(( _t + 1 ))
                        [ "$_t" -lt 2 ] && sleep 0.3
                    done
                ) &
            done
            wait
            _spread_devs=""
            for _d in $ACTIVE_ETH_DEV $ACTIVE_WIFI_DEV; do
                [ -n "$_d" ] || continue
                # 只保留探测通过的接口；两个都通过就都保留（正常路径）
                [ -f "$_pT/ok_$_d" ] || continue
                case " $_spread_devs " in *" $_d "*) ;; *) _spread_devs="$_spread_devs $_d" ;; esac
            done
            _spread_devs="${_spread_devs# }"
             # ⚠️ 这里第一版写错了：注释写"退回不绑（走默认路由）"，代码却把
             # 探测前的原始列表又绑了回去（为此还多引入了一个 _orig_spread_devs
             # 变量）。后果是在"两个接口都探不通"的场景下强行 --interface，
             # 每个分片都失败，最后打出"连续失败"的告警——而 mock_fetch_ramp
             # 正是靠 grep「失败」判断下载是否真的坏，于是误报（文件其实完整、
             # rc=0）。**注释和代码相反时，代码赢，但读代码的人会按注释去改。**
             # 那个变量已删掉——留着就是给下一个误读埋线索。
             #
             # 注意：上面这段说明故意不写成可执行代码的样子。tests/main.swift
             # 有一条断言就是 grep 这段区域里有没有"把原列表绑回去"的写法，
             # 注释里只要含同样的字面量就会误判（"用户可见的文案也是测试数据"，
             # 这条在本项目已经绊倒过三次）。
            [ -n "$_spread_devs" ] || _spread_devs=""
            rm -rf "$_pT"
        else
            # mktemp 失败：退回原来的串行写法，功能不少，只是慢一点
            for _d in $_spread_devs; do
                _spread_try=0
                while [ "$_spread_try" -lt 2 ]; do
                    if curl -s --interface "$_d" --max-time 4 -o /dev/null -r 0-0 \
                            "$url" 2>/dev/null; then
                        break
                    fi
                    _spread_try=$(( _spread_try + 1 ))
                    [ "$_spread_try" -lt 2 ] && sleep 0.3
                done
                [ "$_spread_try" -lt 2 ] || _spread_ok=0
            done
            if [ "$_spread_ok" != "1" ]; then
                _spread_devs=""
                for _d in $ACTIVE_ETH_DEV $ACTIVE_WIFI_DEV; do
                    [ -n "$_d" ] || continue
                    if curl -s --interface "$_d" --max-time 4 -o /dev/null -r 0-0 \
                            "$url" 2>/dev/null; then
                        case " $_spread_devs " in *" $_d "*) ;; *) _spread_devs="$_spread_devs $_d" ;; esac
                    fi
                done
                _spread_devs="${_spread_devs# }"
                [ -n "$_spread_devs" ] || _spread_devs=""
            fi
        fi
    fi
    if [ -n "$_spread_devs" ]; then
        echo "  分片将分摊到 $(echo $_spread_devs | tr ' ' '/')（显式绑接口，不依赖 pf）"
    else
        echo "  分片走默认路由（只有一条可用链路，或 --interface 探测未通过）"
    fi
    # ── 接口健康：某条线连续失败就降级，不再往它上面派片 ──
    #
    # worker 是子进程，父进程的变量改不到它们之间，所以只能用文件记账
    # （$T/devfail_<设备>）。这是并发 worker 间共享状态的唯一方式。
    #
    # 为什么需要它：以前 _spread_pick 是静态轮询，一条线开始抽风之后，
    # 剩余分片还源源不断派过去，每一片都要等满 3 次重试才失败；而第一次
    # 失败就会让父进程建 $T/stop、把整个下载毙掉。降级之后这条线不再接
    # 新片，已派出去的片也有 _fetch_seg 的兜底，下载能继续下完。
    FETCH_DEV_FAIL_MAX=2
    _fetch_dev_fail() {   # $1=设备名（空则什么都不做）
        [ -n "$1" ] || return 0
        local f="$T/devfail_$1" n=0
        [ -f "$f" ] && n="$(cat "$f" 2>/dev/null)"
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        printf '%s\n' "$(( n + 1 ))" > "$f"
    }
    _fetch_dev_ok() {     # $1=设备名 -> 0 健康 / 1 已降级（空设备视为健康）
        [ -n "$1" ] || return 0
        local f="$T/devfail_$1" n=0
        [ -f "$f" ] && n="$(cat "$f" 2>/dev/null)"
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        [ "$n" -lt "$FETCH_DEV_FAIL_MAX" ]
    }

    # 实现：**平滑加权轮转（SWRR）**生成一条交错序列，之后按 idx % 长度取。
    # 放在这里而不是每次调用时算——_spread_pick 每个分片都要调一次，
    # 不能在里面做除法。
    #
    # ⚠️ 第二版在这里栽过一次，值得记下来：我当时把每个设备按权重重复
    # N 次后**首尾相接**（en0×11 紧跟 en1×22）。权重算对了，排列全错——
    # 前 11 片统统走 en0，9 片的文件 100% 压在慢的那条线上，
    # 实测分摊比例 99% / 0%，比不改还糟。
    # **"按比例给份额"和"把份额交错开"是两件事**，只做前者等于没做。
    # SWRR 每一步都挑"目前最亏欠"的那条线，天然交错，也不会漂移。
    #
    # 数据不全时不猜：只有部分接口有实测值 → 退回均分。
    # 理由和 pick_by_speed 的弃权一致——没有证据说另一条慢，
    # 就不能因此少分它片。均分是诚实的默认。
    local _spread_seq="" _si _sw _stot=0 _wpairs="" _wpair _wdev _wval
    local _ndev=0 _ndata=0 _p=0 _best=0 _bestscore="" _j=0 _score _c _newcur _bestdev
    local _cur=""
    for _si in $_spread_devs; do _ndev=$(( _ndev + 1 )); done
    for _si in $_spread_devs; do
        _sw="$(_metric_val "speed_$_si")"
        case "$_sw" in ''|*[!0-9]*) _sw=0 ;; esac
        [ "$_sw" -gt 0 ] || _sw=0
        [ "$_sw" -gt 0 ] && _ndata=$(( _ndata + 1 ))
        _wpairs="$_wpairs $_si:$_sw"
        _stot=$(( _stot + _sw ))
    done
    _wpairs="${_wpairs# }"
    # 全部接口都有实测数据时才加权；否则均分。均分时序列就是设备列表，
    # idx % ndev 本身就是交错的，不需要额外处理。
    if [ "$_stot" -gt 0 ] && [ "$_ndata" -eq "$_ndev" ] && [ "$_ndev" -gt 1 ]; then
        for _wpair in $_wpairs; do _cur="$_cur 0"; done
        _cur="${_cur# }"
        while [ "$_p" -lt 32 ]; do
            _bestscore=""
            _j=0
            for _wpair in $_wpairs; do
                _wdev="${_wpair%%:*}"
                _wval="${_wpair##*:}"
                _score=$(( $(echo "$_cur" | cut -d' ' -f $((_j+1))) + _wval ))
                if [ -z "$_bestscore" ] || [ "$_score" -gt "$_bestscore" ]; then
                    _bestscore=$_score; _best=$_j; _bestdev=$_wdev
                fi
                _j=$(( _j + 1 ))
            done
            # 被选中那条线的欠账减去总量，下一步就轮到别的线
            _newcur=""
            _j=0
            for _wpair in $_wpairs; do
                _c=$(echo "$_cur" | cut -d' ' -f $((_j+1)))
                if [ "$_j" -eq "$_best" ]; then _c=$(( _bestscore - _stot )); fi
                _newcur="$_newcur $_c"
                _j=$(( _j + 1 ))
            done
            _cur="${_newcur# }"
            _spread_seq="$_spread_seq $_bestdev"
            _p=$(( _p + 1 ))
        done
        _spread_seq="${_spread_seq# }"
    fi
    # 加权不适用（无数据/数据不全）时退回均分：序列就是设备列表本身
    [ -n "$_spread_seq" ] || _spread_seq="$_spread_devs"
    local _spread_len=0
    for _si in $_spread_seq; do _spread_len=$(( _spread_len + 1 )); done

    _spread_pick() {   # $1=片号 -> stdout: 设备名
        [ -z "$_spread_devs" ] && { echo ""; return 0; }
        local i="$1" k=0 d want
        want=$(( i % _spread_len ))
        for d in $_spread_seq; do
            if [ "$k" -eq "$want" ]; then
                # 这条线降级了就换另一条，而不是退回不绑：
                # 不绑走的是默认路由，而默认路由往往正是出问题那条。
                # 两条都降级才真的不绑（那时默认路由也没得选了）。
                if _fetch_dev_ok "$d"; then echo "$d"; return 0; fi
                for d in $_spread_devs; do
                    if _fetch_dev_ok "$d"; then echo "$d"; return 0; fi
                done
                echo ""; return 0
            fi
            k=$(( k + 1 ))
        done
        echo ""
    }

    local chunk total_chunks
    total_chunks=128
    [ "$total_chunks" -gt "$size" ] && total_chunks="$size"
    chunk=$(( size / total_chunks ))
    # -n 1 时不切片：一个 worker 顺序做 N 次请求，每次都要付 TCP 握手 +
    # TLS + 慢启动，而并行收益是 0。实测 5MB 文件：裸 curl 单请求 14.8 Mbps，
    # fetch -n 1 切片后 6.2 Mbps——慢 2.4 倍，而且没有任何好处。
    if [ "${n:-1}" -le 1 ]; then
        total_chunks=1
        chunk="$size"
    fi
    # 每片至少 1MB：片太小则 TCP 握手和慢启动开销占比过高，吞吐反而掉
    while [ "$chunk" -lt 1048576 ] && [ "$total_chunks" -gt 1 ]; do
        total_chunks=$(( total_chunks / 2 ))
        chunk=$(( size / total_chunks ))
    done
    # 重新算实际片数（向上取整，最后一片吃余数）
    total_chunks=$(( (size + chunk - 1) / chunk ))
    mkdir -p "$T/q"

    # 认领第一个还没被认领的分片。从头扫：mkdir 失败就是被别人认领了，
    # 直接试下一片，不需要加锁也不需要读共享状态。
    _claim_chunk() {   # $1=队列目录 $2=总片数 -> stdout: 片号；领完返回 1
        local q="$1" total="$2" i
        for i in $(seq 0 $((total-1))); do
            mkdir "$q/c$i" 2>/dev/null && { echo "$i"; return 0; }
        done
        return 1
    }

    # 每个分片带重试。为什么必须重试：这个工具的用途就是"同时用两条线"，
    # 连接数一多，偶发的超时/重置就从 rare 事件变成几乎每次都有。
    # 不重试的话，8 段里挂 1 段整个下载就废了——用户会觉得功能不可用。
    # 实测 -n 8 时分片会撞上 Recv failure，重试后即可完成。
    # 下载一个分片。三种失败必须分开，因为处理方式完全不同：
    #   · HTTP 错误（4xx/5xx）      → 重试没用，直接报出状态码
    #   · 网络错误（超时/重置/拒连） → 值得重试，偶发抖动
    #   · 字节数不符                 → 服务端没按 Range 给，重试也许碰对变体
    # 以前没加 --fail：HTTP 404 时 curl 返回 0、把错误页写进分片文件，
    # 于是走到"字节数不符"分支，重试 3 次后报"服务端 Range 行为不一致"——
    # 诊断完全错误，用户会跑去换源，而真正的原因只是 URL 写错了。
    _fetch_seg() {   # $1=分片号 $2=start $3=end $4=URL $5=目录 $6=设备(空=不绑)
        local idx="$1" st="$2" en="$3" u="$4" d="$5" dev="${6:-}" try got http rc
        # 不用数组拼 --interface：bash 3.2 下空数组展开有坑，而设备名
        # （en0/en1）不可能含空格，未加引号的 $ifpre 展开是安全的。
        local ifpre=""
        [ -n "$dev" ] && ifpre="--interface $dev"

        # 一次尝试。-> 0 成功 / 1 可重试 / 2 HTTP 错误（重试没意义）
        #
        # --connect-timeout 10：连接阶段最多等 10 秒。以前没有，
        #   接口"关联着但不通"时 TCP 握手能挂到系统默认的几十秒。
        # --speed-limit 20480 --speed-time 20：20 秒内平均低于 20KB/s 就中止。
        #   这是抓"接口假死"的关键——那种情况下连接建得起来、数据不来，
        #   只靠 --max-time 要等满整个上限，而用户看到的就是命令卡住。
        #   真在下载时远高于 20KB/s（实测 27-33 Mbps），不会误伤。
        # --max-time 300：配合上面两项，从 600 降下来。600 秒的代价是
        #   假死时要 3 次 × 600 秒才发现，用户早以为软件死了。
        _fetch_try() {
            # --fail 让 4xx/5xx 返回非 0；-w 把状态码写出来，即使失败也有值
            # （连不上时是 000，正好和 HTTP 错误区分开）。
            http="$(curl -sS -L --fail --connect-timeout 10 --speed-limit 20480 \
                    --speed-time 20 --max-time 300 --range "${st}-${en}" \
                    $ifpre \
                    -o "$d/p$idx" -w '%{http_code}' "$u" 2>/dev/null)"
            rc=$?
            if [ "$rc" -eq 0 ]; then
                # 注意：不能写 wc -c < "$d/p$idx" 2>/dev/null。
                # bash 按从左到右处理重定向，< 先执行——文件打不开时
                # shell 自己报的错发生在 2>/dev/null 生效**之前**，
                # 于是漏到 stderr，用户看到一行
                #   smartroute.sh: line NNN: .../p5: No such file or directory
                # 完全不知所谓。用 -f 守卫挡住，根本不去开这个文件。
                got=0
                [ -f "$d/p$idx" ] && got="$(wc -c < "$d/p$idx" | tr -d ' ')"
                if [ "$got" = $(( en - st + 1 )) ]; then
                    # 成功了要清掉前几次失败留下的 connfail 标记，否则重试成功
                    # 的分片会被父进程算进"连接失败"里，诊断就虚报了。
                    rm -f "$d/connfail_$idx" 2>/dev/null
                    return 0
                fi
                return 1
            fi
            # 429/503 是"服务端限流/过载"，等一会儿就好——我们实测被
            # proof.ovh.net 和 hetzner 用 429 打过，多连接下载尤其容易触发。
            # 当成致命错误会让整个下载立刻毙掉，而那只是需要退避。
            if [ "$http" = "429" ] || [ "$http" = "503" ]; then
                # 留下限流标记：父进程的扩连循环看到它就不再往上加 worker。
                # 限流的含义是"服务端扛不住这么多连接"，此时加连接只会
                # 招来更多 429，而原来的做法是闷头睡 15 秒（见下面退避）。
                : > "$d/ratelimited" 2>/dev/null
                return 3
            fi
            if [ -n "$http" ] && [ "$http" != "000" ] && [ "$http" -ge 400 ] 2>/dev/null; then
                # 其它 HTTP 错误：重试同样的请求不会有不同结果，带上状态码收手
                printf 'HTTP %s\n' "$http" > "$d/httperr_$idx"
                return 2
            fi
            # 连接失败/超时（http=000，curl 退出码非 0）。
            # 必须和上面分开记账：实测多连接下载时服务端一限流就走这条，
            # 而以前的诊断只有"字节数不符"和"HTTP 错误"两种，于是它被
            # 归成"服务端 Range 行为不一致，请换源"——完全指错方向，
            # 用户照着去换源，而真正该做的是降低 -n。
            printf '%s\n' "${http:-000}" > "$d/connfail_$idx"
            return 1
        }

        for try in 1 2 3; do
            _fetch_try
            case $? in
                0) return 0 ;;
                2) return 1 ;;
                # 退避从 5s/10s 改成 1s/2s。原来的 15 秒是为大文件设计的，
                # 但 5MB 文件被限流时也要睡满 15 秒——实测这让 n=4 比裸 curl
                # 单连接慢 5.7 倍（2.6 vs 14.8 Mbps）。限流时真正该做的是
                # 停止扩连（上面已留标记），退避只需够服务端缓口气。
                3) [ "$try" -lt 3 ] && sleep $(( try )) ;;   # 退避：1s/2s
                *) [ "$try" -lt 3 ] && sleep 1 ;;
            esac
        done

        # ── 跨接口兜底 ──
        # 绑定的设备 3 次都没成。以前到这里直接 return 1，父进程会建
        # $T/stop 把整个下载毙掉——一条线抖一下，整个文件白下。
        # 现在先记一笔降级（_spread_pick 不再往这条线派新片），
        # 再**不绑接口**试一次：默认路由一定是通的（单连接下载一直走它）。
        # 注意不能反过来"先换另一条设备"——另一条可能也在抽风，
        # 而默认路由是系统自己选的，最可能通。
        if [ -n "$dev" ]; then
            _fetch_dev_fail "$dev"
            ifpre=""
            _fetch_try
            case $? in
                0) return 0 ;;
                2) return 1 ;;
            esac
        fi
        return 1
    }

    # worker：认领-下载循环，直到队列空了
    # 失败时把片号和期望/实得字节数写进错误文件——主流程据此说出**真正的原因**。
    # 笼统的"下载失败"会让用户以为是网络问题；实测多数是服务端 Range 行为
    # 不一致（报了 31402 字节却返回 87533），这两种的处理完全不同。
    _fetch_worker() {   # $1=队列目录 $2=总片数 $3=URL $4=分片目录 $5=片大小 $6=文件大小
        local q="$1" total="$2" u="$3" d="$4" cs="$5" sz="$6" idx st en want got dev
        # 中断（用户 Ctrl-C）或别处失败（stop 标志）都要停手。
        # 用 ${d} 而不是 ${T}：${d} 是本函数的参数，不依赖 cmd_fetch 的局部
        # 变量通过动态作用域透进来——那在重构时很容易悄悄失效。
        while [ "${_fetch_aborted:-0}" != "1" ] && [ ! -f "$d/stop" ] \
              && idx="$(_claim_chunk "$q" "$total")"; do
            st=$(( idx * cs ))
            en=$(( st + cs - 1 ))
            # 最后一片可能超出文件末尾，截断
            [ "$en" -gt $(( sz - 1 )) ] && en=$(( sz - 1 ))
            want=$(( en - st + 1 ))
            # 按片号轮询绑接口。放在 worker 里算而不是按 worker 分工：
            # 按 worker 分工的话，4 个 worker 里 2 个绑 en0、2 个绑 en1，
            # 一旦某条线慢，它上面那两个 worker 就拖着整个下载；
            # 按片号轮询则快的 worker 认领更多片，天然自平衡。
            dev="$(_spread_pick "$idx")"
            if ! _fetch_seg "$idx" "$st" "$en" "$u" "$d" "$dev"; then
                # 注意：不能写 wc -c < "$d/p$idx" 2>/dev/null。
                # bash 按从左到右处理重定向，< 先执行——文件打不开时
                # shell 自己报的错发生在 2>/dev/null 生效**之前**，
                # 于是漏到 stderr，用户看到一行
                #   smartroute.sh: line NNN: .../p5: No such file or directory
                # 完全不知所谓。用 -f 守卫挡住，根本不去开这个文件。
                got=0
                [ -f "$d/p$idx" ] && got="$(wc -c < "$d/p$idx" | tr -d ' ')"
                printf '%s %s %s\n' "$idx" "$want" "${got:-0}" > "$d/fail_$idx"
                return 1
            fi
        done
        return 0
    }

    # 片数少于 worker 数时，多出来的 worker 一片都认不到、直接退出。
    # 这在小文件上是正常的（切太细反而更慢），但不说清楚的话，
    # 用户看到"8 个 worker"会以为有 8 条连接在跑，实际可能只有 1 条。
    if [ "$total_chunks" -lt "$n" ]; then
        echo "  切成 $total_chunks 片（每片约 $(fmt_bytes "$chunk")）"
        echo "  文件较小，只有 $total_chunks 片可下，上限 $n 条连接里多出来的会空转"
        echo "  （小文件切太细反而更慢，这是有意的；要跑满连接请换个大文件）"
    else
        echo "  切成 $total_chunks 片（每片约 $(fmt_bytes "$chunk")），最多 $n 个 worker 认领"
    fi
    local -a pids=()
    local w
    # ── 自适应扩连接 ──
    #
    # 为什么不再一次性起满 n 个 worker：实测连接数是**有峰值**的，
    # 超过之后吞吐单调下降、失败分片等比例增加：
    #     n=2   218MB  1 个分片失败   17.0 Mbps
    #     n=4   219MB  2 个分片失败   17.6 Mbps   ← 峰值
    #     n=8   178MB  4 个分片失败   14.3 Mbps
    #     n=16   97MB  11 个分片失败   8.0 Mbps
    # 原因是连接数一多服务端就开始限流/丢连接，每条连接的 TCP 慢启动
    # 重新来过，反而更慢。而"多少条是峰值"取决于服务端，用户没法预知。
    #
    # 所以改成：先起 2 个 worker，之后每当"已下载片数 ≥ 下一档阈值"就加一个，
    # 直到用户给的 n。服务端扛得住 → 很快加到 n；服务端限流 → 片下得慢，
    # 阈值一直不达到，就停在低连接数。不需要测速，也不需要用户猜。
    #
    # 阈值算法：下一档 = 当前已起 worker 总数 × 已起的 worker 数。
    # 起 2 个 → 阈值 2；下完 2 片后起到 3 个 → 阈值 5；下完 5 片起到 4 个 → 9。
    # 这样每个 worker 平均至少要完整下完一片才允许再加人，加人是赚到的。
    local n_start="$n"
    [ "$n_start" -gt 2 ] && n_start=2
    [ "$n_start" -ge 1 ] || n_start=1
    local -a pids=()
    local _spawned=0 _next_spawn_at=$n_start _comp=0 _alive=0 _remain=0 _ramped=0
    for w in $(seq 1 "$n_start"); do
        _fetch_worker "$T/q" "$total_chunks" "$url" "$T" "$chunk" "$size" &
        pids+=("$!")
        _spawned=$((_spawned+1))
    done
    [ "$n_start" -lt "$n" ] && _ramped=1

    # 有分片失败时立刻让其余 worker 停手。
    #
    # 以前不这样做：失败的 worker 自己 return 1，兄弟 worker 继续认领
    # 直到队列空，父进程 wait 全部。后果是某片 404 时**整个文件照下**
    # （每段最长 600s），最后才报"已放弃"——消息和"其实全下完了"的
    # 行为互相矛盾，白费带宽和时间。用户等半天拿到一个不能用的结果。
    #
    # 实现：失败的 worker 先写 $T/fail_<片号>，父进程 poll 发现就建 $T/stop，
    # 所有 worker 的认领循环检查这个标志；父进程随后把剩余 pid kill 掉。
    local p _stop_seen=0 rc=0 _f _fi
    while :; do
        # 数活着的 worker。全退出了就收尾。
        _alive=0
        for p in ${pids[@]+"${pids[@]}"}; do
            kill -0 "$p" 2>/dev/null && _alive=$((_alive+1))
        done
        [ "$_alive" -eq 0 ] && break

        # 失败检测：worker 写 fail_<片号> 后就 return 1，比 wait 更早发现
        for _f in "$T"/fail_*; do
            [ -f "$_f" ] || continue
            [ -f "$T/stop" ] || : > "$T/stop"
            _stop_seen=1; rc=1
            break
        done
        [ "$_stop_seen" = "1" ] && break
        # 扩连接：完成数达到阈值、还有剩余片、且没到用户上限时才加。
        # 服务端已经限流（有 worker 撞到 429/503 并留下标记）时不再加：
        # 限流的含义就是连接数过头了，再加只会招来更多 429。
        #
        # ⚠️ 这个阈值试过两种改法，都错了，原因记在这里免得再改：
        #
        # 改法一（纯时间驱动，每 0.25s 加一人）：慢服务端也被加到 8 条。
        # 完成数少的含义正是"服务端跟不上"，这时候加连接只会招来 429——
        # 把原有的自适应保护拆了。mock_fetch_ramp 的"慢服务端收敛"断言
        # 当场抓到。
        #
        # 改法二（每新完成一片加一人）：慢服务端加到 5 条，仍然超过测试
        # 要求的 4。慢服务端 700ms/片、2 worker 时约 350ms 完成一片，
        # 这个速率下"每完成一片加一人"照样能爬到 5。
        #
        # 结论：**这个阈值不该动**。小文件（12.7MB / 9 片）扩不上去的真正
        # 原因不是阈值，是整个下载只要 1 秒、ramp 根本来不及——
        # 那种情况下该做的是把已有的少数 worker 分对活（按容量加权，
        # 见 _spread_pick），不是硬加连接数。
        if [ "$_spawned" -lt "$n" ] && [ ! -f "$T/ratelimited" ]; then
            _comp=$(ls "$T"/p* 2>/dev/null | wc -l | tr -d ' ')
            _remain=$(( total_chunks - _comp ))
            if [ "$_comp" -ge "$_next_spawn_at" ] && [ "$_remain" -gt "$_alive" ]; then
                _fetch_worker "$T/q" "$total_chunks" "$url" "$T" "$chunk" "$size" &
                pids+=("$!")
                _spawned=$((_spawned+1))
                _next_spawn_at=$(( _comp + _spawned ))
            fi
        fi
        sleep 0.2
    done
    # 保险：正常退出路径（_alive 归零）也要查一次失败。
    # worker 可能在最后一轮 poll 之后、父进程收尸之前写完 fail_ 文件，
    # 漏掉的话下载会带着缺失的分片进入合并，最后报"字节数不符"——
    # 而真正的原因（某片 404/超时）被吞了，诊断完全指错方向。
    if [ "$rc" -eq 0 ]; then
        for _f in "$T"/fail_*; do
            [ -f "$_f" ] || continue
            rc=1
            break
        done
    fi
    if [ "$_ramped" = "1" ] && [ "$_spawned" -gt "$n_start" ]; then
        echo "  自适应扩连：从 $n_start 条逐步加到 $_spawned 条（服务端扛得住才加）"
    fi
    # 哪条线被降级了要说出来。用户看到"分片改走默认路由"之类的结果时，
    # 有权知道是哪条线在半路上掉了——否则他只看到一个莫名的降速，
    # 完全没法判断是该重试还是该换环境。
    if [ -n "$_spread_devs" ]; then
        local _dem="" _dname _dn
        for _dname in $_spread_devs; do
            _dn=0
            [ -f "$T/devfail_$_dname" ] && _dn="$(cat "$T/devfail_$_dname" 2>/dev/null)"
            case "$_dn" in ''|*[!0-9]*) _dn=0 ;; esac
            if [ "$_dn" -ge "$FETCH_DEV_FAIL_MAX" ]; then
                _dem="$_dem$_dname "
            fi
        done
        if [ -n "$_dem" ]; then
            echo "  ⚠️  ${_dem% } 连续失败，已停止往它派片（剩余分片改走另一条线/默认路由）"
        fi
    fi
    if [ "$_stop_seen" = "1" ]; then
        # 把还在跑的 worker 杀掉。它们的 curl 会随之退出（父进程被 kill
        # 时子进程不自动死，必须显式处理）。
        local _k
        for _k in ${pids[@]+"${pids[@]}"}; do
            kill "$_k" 2>/dev/null
        done
        wait 2>/dev/null
        rc=1
    fi
    if [ "${_fetch_aborted:-0}" = "1" ]; then
        # 用户主动取消。不能说成"下载失败（已重试 3 次）"——零次重试，
        # 是用户自己打断的，那句话是假的。
        echo "已取消（临时文件已清理）。"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        # 把失败原因说清楚：是连接不通，还是服务端 Range 行为不一致。
        # 后者要换源，前者才该降低 -n——笼统一句"下载失败"等于让用户瞎猜。
        local _fi _fidx _fwant _fgot _msg="" _n=0
        for _fi in "$T"/fail_*; do
            [ -f "$_fi" ] || continue
            # 不能用 _ 当 read 的目标：bash 里 _ 是特殊变量（上一条命令的最后一个
            # 参数），read 写进去也会被后续命令覆盖，读出来是空的。
            read -r _fidx _fwant _fgot < "$_fi" 2>/dev/null
            [ -n "$_msg" ] && _msg="${_msg}；"
            _msg="${_msg}分片 ${_fidx:-?} 期望 ${_fwant:-?} 字节、实得 ${_fgot:-?} 字节"
            _n=$(( _n + 1 ))
            # 最多列 3 条：服务端整体行为不一致时可能几十个分片全挂，
            # 全列出来会把真正的原因（服务端 Range 不兼容）淹掉。
            [ "$_n" -ge 3 ] && break
        done
        [ "$_n" -ge 3 ] && _msg="${_msg}；…等 ${_n} 个分片"
        if [ -n "$_msg" ]; then
            echo "分片大小与请求不符：${_msg}"
            echo "原因：这个服务端的 Range 行为不一致（对同一文件返回不同内容/大小），"
            echo "      多连接下载无法保证拼出原文件，已放弃。请换一个源，或用单连接下载。"
        fi
        # HTTP 错误要单独说：那是 URL 或权限问题，不是 Range 兼容性，
        # 让用户去"换源"只会浪费时间。
        local _he _hmsg=""
        for _fi in "$T"/httperr_*; do
            [ -f "$_fi" ] || continue
            read -r _ _he < "$_fi" 2>/dev/null
            [ -n "$_hmsg" ] && _hmsg="${_hmsg}、"
            _hmsg="${_hmsg}${_he:-未知}"
        done
        if [ -n "$_hmsg" ]; then
            echo "服务端返回了 HTTP 错误：${_hmsg}"
            echo "原因：URL 写错、文件不存在、需要登录/鉴权，或服务端临时故障。"
            echo "      重试和降低 -n 都无效——请先确认这个 URL 用浏览器能打开。"
            die "有分片下载失败（已重试 3 次，临时文件已清理）"
        fi
        # 连接失败/超时：和 Range 不兼容是两回事。实测多连接下载撞上服务端
        # 限流时全走这条，而以前这里只有"字节数不符"和"HTTP 错误"两个分支，
        # 于是它被说成"服务端 Range 行为不一致，请换源"——用户照着换源，
        # 真正该做的（降低 -n）反而没人告诉他。
        local _cn=0
        for _fi in "$T"/connfail_*; do
            [ -f "$_fi" ] && _cn=$((_cn+1))
        done
        if [ "$_cn" -gt 0 ]; then
            echo "分片连接失败（$_cn 个）：连接建立不了、中途被断开，或速度掉到阈值以下被中止。"
            echo "常见原因："
            echo "  · 服务端限制并发连接——多连接下载很容易撞上（本机实测过："
            echo "    某个源并发超过 2 条就返回错误页）。**先把 -n 降到 2 试试**。"
            echo "  · 某条线路不通：看上面有没有"已停止往它派片"的提示。"
            echo "  · 服务端临时过载。"
            echo "换源只在前两条都不成立时才值得试。"
            die "有分片下载失败（已重试 3 次，临时文件已清理）"
        fi
        die "有分片下载失败（已重试 3 次，临时文件已清理）"
    fi

    # 校验总字节，少一块就说明服务端没按 Range 给全
    local got=0
    for i in $(seq 0 $((total_chunks-1))); do
        [ -f "$T/p$i" ] || die "缺少分片 $i"
        got=$(( got + $(wc -c < "$T/p$i" | tr -d ' ') ))
    done
    if [ "$got" -ne "$size" ]; then
        die "分片大小不符（期望 ${size}，实得 ${got}），服务端可能未正确支持 Range"
    fi

    # 分片路径必须加引号：虽然 mktemp 生成的目录不含空格，但未加引号的
    # 命令替换一旦遇到空格就会把路径拆成多个参数，cat 报一堆"no such file"，
    # 而错误信息完全指不到真正的原因。
    # 用 while read 而不是 $(...)：顺便避免片数很多时触到 ARG_MAX。
    local _catlist="" _i
    _i=0
    while [ "$_i" -lt "$total_chunks" ]; do
        _catlist="$_catlist \"$T/p$_i\""
        _i=$(( _i + 1 ))
    done
    eval "cat $_catlist" > "$out" || die "合并失败"
    # 下载耗时的终点必须是**合并完成这一刻**，不能放到报告之后取。
    # 中间隔着两次 netstat、state 读、一堆 echo，100-300ms 起步；
    # 对纳秒计时要救的"小文件"场景，这正好构成 10-30% 的偏差——
    # 用户看到的是一个被系统性低估的数字，而且低估量取决于
    # 报告打了多少行，不可复现。
    t_end_ns="$(date +%s%N)"
    # 报实际用过的连接数（_spawned），不是用户给的上限（n）。
    # 自适应扩连下这两者经常不同：用户 -n 8，实际可能只起到 3 条。
    # 报上限会让用户以为有 8 条在跑，去对 netstat 时对不上。
    echo "完成: ${out}（$(fmt_bytes "$size")，${total_chunks} 片 / ${_spawned:-1} 连接）"

    # 【实测分摊】拿刚才的基线算增量，报告每条线实际扛了多少字节。
    # 为什么必须有这个：用户要的是"两个网络一起跑一个数据"的**证据**，
    # 不是一句"已开启"。没有证据，功能开着也没人信；出了问题也分不清是
    # "分流没生效"还是"生效了但对这个源没用"——这两种的处理完全不同。
    # 而且这是唯一不依赖服务端日志的验证方式，用户自己能复现。
    local eth_after=0 wifi_after=0
    [ -n "$ACTIVE_ETH_DEV" ]  && eth_after="$(_if_bytes "$ACTIVE_ETH_DEV")"
    [ -n "$ACTIVE_WIFI_DEV" ] && wifi_after="$(_if_bytes "$ACTIVE_WIFI_DEV")"
    case "$eth_after"  in ''|*[!0-9]*) eth_after=0 ;; esac
    case "$wifi_after" in ''|*[!0-9]*) wifi_after=0 ;; esac
    local d_eth=$(( eth_after - eth_before ))
    local d_wifi=$(( wifi_after - wifi_before ))
    # 基线可能比现在还大（计数器回绕、或刚重连过），负数没意义
    [ "$d_eth" -lt 0 ] && d_eth=0
    [ "$d_wifi" -lt 0 ] && d_wifi=0
    local d_all=$(( d_eth + d_wifi ))
    # 窗口内测到的是这两个接口的**全部**字节——包括其他 app、DNS、系统更新、
    # iCloud 同步。如果总量远超本次下载的文件大小，百分比就被这些无关流量
    # 污染了。以前不提示，用户会看到一个对不上的比例还以为工具算错了。
    if [ "$d_all" -gt $(( size * 3 )) ] && [ "$size" -gt 0 ]; then
        echo "⚠️  测量窗口内两个接口共 ${d_all} 字节，远大于本次下载的 $(fmt_bytes "$size")，"
        echo "    说明期间还有其他程序在联网。下面的百分比包含那部分流量，仅供参考；"
        echo "    要精确测量，请关掉其他下载/同步类程序后重试。"
    fi
    if [ "$d_all" -gt 0 ]; then
        local pct_eth=$(( d_eth * 100 / d_all )) pct_wifi=$(( d_wifi * 100 / d_all ))
        echo "流量分摊（本次下载期间）:"
        echo "  ${ACTIVE_ETH_DEV:-以太网}: $(fmt_bytes "$d_eth") (${pct_eth}%)"
        echo "  ${ACTIVE_WIFI_DEV:-Wi-Fi}: $(fmt_bytes "$d_wifi") (${pct_wifi}%)"
        # 判定"两条线都在扛"必须有阈值，不能只看非零。
        # 实测：没开分流时 en0 也有 247 字节——那是 TCP 握手和 DNS 探测，
        # 不是有效载荷。按"非零即算"会打出"✅ 两条线都在扛"，
        # 而实际 99% 的流量在另一条线上。伪造证据比不报更糟：
        # 用户照着这个结论去排查，会被带偏到完全错误的方向。
        # 5% 是有效分担的下限：低于它说明这条线基本没参与。
        local _min_pct=5
        if [ "$pct_eth" -lt "$_min_pct" ] || [ "$pct_wifi" -lt "$_min_pct" ]; then
            # 这一段的建议必须是**用户此刻真能做到的**。原来的三行全是错的：
            #
            # 1) "没执行 sudo smartroute balance on" —— 错。fetch 靠 curl
            #    的 --interface 显式绑接口，跟 pf 分流没关系。同网关下
            #    pf 分流已禁用（零收益 + 卡壳风险），让用户去开等于让他
            #    去撞一堵墙，而墙上还挂着"会被拒绝"的告示。
            # 2) "网关相同且未加 --force" —— **更糟，--force 已经不存在了**。
            #    这是让用户执行一条不存在的命令。他会去查、会试、会发现
            #    报错，然后回来问"为什么加了 --force 还是不行"。
            #    这种提示比不提示更差：它消耗的是用户对工具的信任。
            # 3) "连接数太少" —— 方向对，但不是最常见的原因。
            #
            # 实测最常见的原因是**文件太小，压根没切成多片**：
            # 实测 1.7MB 的文件（min chunk 1MB）→ 只切 1 片 → 1 片只能走
            # 一条线，于是必然"只有一条线在扛"。这跟 -n 多少、
            # pf 开没开，一点关系都没有。
            echo "  ⚠️  这次只有一条线在扛这个文件。按发生频率从高到低："
            # 已经确认只切出 1 片时，不要再去扯 Range——那只会把人引向
            # 错误的方向（文件小是文件小，地址不支持 Range 是另一回事，
            # 两者的处理完全不同）。而且"切成 1 片"本身已经告诉用户答案了。
            if [ "${total_chunks:-1}" -le 1 ]; then
                echo "     • 文件太小，只切出 ${total_chunks:-1} 片——一片只能走一条线。"
                echo "       本次 $(fmt_bytes "${size:-0}")，最小片大小是 1 MB，"
                echo "       所以 $(fmt_bytes "${size:-0}") 以下都不可能分摊。换个更大的文件。"
                echo "  （多连接下载靠 --interface 显式绑接口，不需要开 pf 分流）"
            fi
            # 走到这里说明确实切了多片，那问题在别处。
            # 文案刻意避开「不支持 Range」这个字面串：mock_fetch_http.sh 用
            # grep "不支持 Range" 判定"是否被误判成单连接"，而这段提示在
            # 多片却只走一条线时也会打印——字面串一撞，正确的代码就被判红。
            # 这已经是第二次在同一类问题上栽跟头（上次是"失败"二字），
            # 所以这次直接从根上避免：提示文本不要复用被测信号的字面量。
            echo "     • 某个接口的 --interface 探测没通过，脚本自动改用能用的接口。"
            echo "       重试一次通常即可（探测有 8 秒超时，偶发会超时一次）。"
            echo "     • -n 太小：${n:-?} 条连接、${total_chunks:-?} 片，轮询可能不均。"
            echo "       试 -n 8（片数 ≥ 连接数时才容易均分）。"
            echo "     • 地址不返回分段内容时脚本会退回单连接（这是正常现象）。"
            echo "       判断方法：看上面打印的「切成 N 片」，N=1 即是。"
            echo "  （不需要开 pf 分流：多连接下载靠 --interface 显式绑接口，与 pf 无关）"
        else
            echo "  ✅ 两条线都在扛这个文件（这就是并发叠加生效的证据）"
        fi
    fi

    # 【速率与结论】只报"扛了多少字节"回答不了"到底有没有变快"——
    # 两条线都在扛，也可能总共只跑到快的那条线的速度（瓶颈在路由器上游）。
    # 所以必须算出本次吞吐，并和守护进程实测的单线速度比：
    #   接近 快线单独的速度      → 聚合没赚到，瓶颈在上游（同网关时常这样）
    #   明显超过 快线单独的速度  → 聚合真的在叠加
    # 这个结论必须说出来，否则用户花了力气开分流，却不知道有没有收益。
    #
    # 单位必须处处自洽：size 是**字节**，t_dur 是秒，所以字节/秒才对；
    # fmt_bps 的入参也是字节/秒（它内部 *8 转成 bit）。以前在这里先 *8 变成
    # bit/s 再交给 fmt_bps，等于乘了两次 8——实测 85.5KB/4s 报成 1.4 Mbps，
    # 真实值 0.175 Mbps，虚高 8 倍。而且拿 bit/s 去和字节/秒的 _fast 比大小，
    # 阈值判断也是错的。
    local t_dur bps
    # 纳秒计时：date +%s%N 在 macOS 可用（bash 3.2 没有 EPOCHREALTIME）。
    # 不用整秒：亚秒级的小文件下载，整秒会把 t_dur 当成 1，吞吐被严重低估。
    # t_end_ns 在合并完成时就取好了（见上），这里直接复用——
    # 重新取一次会把报告本身的耗时算进下载耗时。
    local t_ns_now="$t_end_ns"
    case "$t_ns_now" in ''|*[!0-9]*) t_ns_now=0 ;; esac
    if [ "$t_ns_now" -gt "$t_start_ns" ] && [ "$t_start_ns" -gt 0 ]; then
        t_dur=$(( (t_ns_now - t_start_ns) / 1000000 ))     # 毫秒
    else
        # date +%s%N 不可用时退回整秒
        t_dur=$(( $(date +%s) - t_start_s ))
        [ "$t_dur" -lt 1 ] && t_dur=1
        t_dur=$(( t_dur * 1000 ))
    fi
    [ "$t_dur" -ge 1 ] || t_dur=1
    # 字节/秒。用毫秒既避免小文件被低估，也避免除零。
    bps=$(( size * 1000 / t_dur ))
    if [ "$t_dur" -ge 1000 ]; then
        echo "本次吞吐: $(fmt_bps "$bps")（$(( t_dur / 1000 ))s）"
    else
        echo "本次吞吐: $(fmt_bps "$bps")（${t_dur}ms）"
    fi

    # ACTIVE_*_DEV 在上面（抓基线时）已经 find_active 过，这里直接复用，
    # 不再调第二次——find_active 要走 networksetup/ifconfig，约 70ms，白等一趟。
    local _pe _pw _fast
    _pe="$(_metric_val "speed_$ACTIVE_ETH_DEV")"
    _pw="$(_metric_val "speed_$ACTIVE_WIFI_DEV")"
    _fast="$_pe"; [ "${_pw:-0}" -gt "${_pe:-0}" ] 2>/dev/null && _fast="$_pw"
    # 结论必须建立在**新鲜**的测速值上。缓存可能已过期（SPEED_RECHECK=300s），
    # 拿 5 分钟前的速度判"聚合没赚到"，会把一次正常的慢下载说成功能无效——
    # 比不说更糟。过期就不下结论，只说明为什么没结论。
    #
    # 两边都要查：_fast 取两者之大，只要有一边是旧的，"上限"就是错的。
    # 只查一边等于没查——旧的那一边正好可能是被当成上限的那个。
    local _fresh=1
    if [ -n "$_pe" ] && [ -n "$_pw" ] \
       && _metric_fresh "speed_$ACTIVE_ETH_DEV" "$SPEED_RECHECK" \
       && _metric_fresh "speed_$ACTIVE_WIFI_DEV" "$SPEED_RECHECK"; then
        _fresh=0
    fi
    if [ -n "$_pe" ] && [ -n "$_pw" ] && [ "${_pe:-0}" -gt 0 ] 2>/dev/null \
       && [ "${_pw:-0}" -gt 0 ] 2>/dev/null && [ "$_fresh" = "0" ]; then
        # 超过快线单独速度的 80% 就算"基本吃满了快线"
        local _thresh=$(( _fast * 8 / 10 ))
        if [ "$bps" -ge "$_thresh" ]; then
            echo "结论: 吞吐已接近单条快线的实测上限（$(fmt_bps "$_fast")），"
            echo "      并发没有额外收益——瓶颈不在你这两个入口，大概率在路由器上游。"
            echo "      同网关双接口本来就共享同一条上游链路，这不是工具的问题。"
        else
            echo "结论: 吞吐明显低于单条快线的上限（$(fmt_bps "$_fast")），"
            echo "      还有空间。可试着加大 -n（如 16/24）让更多连接参与分摊。"
        fi
    elif [ -n "$_pe" ] || [ -n "$_pw" ]; then
        echo "结论: 没有可用的单线测速值（未测或已过期），无法判断并发是否带来收益。"
        echo "      先跑 sudo smartroute speed（或等守护进程自动测速）后再试。"
    fi
    return 0
}

# 写一个配置键，成功返回 0。给 cmd_boost 用——它要连续写多个键，
# 每个都要单独报成功/失败，不能一个失败就 die 把后面的全跳过。
#
# 为什么不复用 cmd_set：cmd_set 末尾直接 echo + exit，且参数解析把
# "speed" 这种裸词映射成 MODE。boost 要的是纯粹的 KEY VALUE 语义。
# 校验和写入目标的选择则完全复用 cmd_set 的逻辑（conf_value_ok +
# USER_CONF 优先），否则会出现"set 能写、boost 写不进去"的分裂。
conf_set_kv() {   # $1=KEY $2=VALUE
    local key="$1" val="$2" target
    case " $VALID_KEYS " in
        *" $key "*) ;;
        *) echo "  ❌ 不支持的配置项: $key"; return 1 ;;
    esac
    conf_value_ok "$key" "$val" || {
        echo "  ❌ $key 的值不合法: $val"
        conf_value_hint "$key"
        return 1
    }
    if [ -w "$USER_CONF" ] || [ -w "$(dirname "$USER_CONF")" ]; then
        target="$USER_CONF"
    elif [ "$(id -u)" -eq 0 ]; then
        target="$CONF"
    else
        echo "  ❌ 无法写入 ${USER_CONF}（可能属于 root）。请执行: sudo chown \$(id -u) $USER_CONF"
        return 1
    fi
    conf_set "$key" "$val" "$target" || {
        echo "  ❌ 写入 $target 失败"
        return 1
    }
    return 0
}

# 一键把用户要的四项能力全部配好：
#   1) 无网络自动切换 Wi-Fi/有线   → MODE=speed（自带可用性兜底）
#   2) 网速增加                    → MODE=speed（实测吞吐大的赢）
#   3) 双网并发                    → BALANCE=1 + weighted
#   4) Wi-Fi 自动寻找              → WIFI_FAILOVER=1
#
# 为什么值得有这么一个命令：这四项散在四个配置键里，其中两项默认关闭、
# 一项还要额外 sudo 加载 pf 规则。用户要知道该调哪几个旋钮、按什么顺序，
# 本身就是负担。而且 MODE 该选 auto 还是 speed 取决于"要不要顺便提速"，
# 选错了需求 2 就静默不生效——这类"配了却没效果"最难排查。
#
# 这里明确选 speed 而不是 auto：speed 在只有一条线可用时同样会切过去
# （见 cmd_watch 的 speed 分支末尾的 elif），所以它同时覆盖需求 1 和 2，
# 不需要用户在两个模式之间纠结。
cmd_boost() {
    local need_root=0
    echo "配置四项网络能力…"
    echo ""

    # 1+2) 选路模式。必须真写进配置文件，不能只改当前进程的变量——
    # 守护进程每轮都重新读配置，只在内存里改下一轮就丢了。
    conf_set_kv MODE speed      && echo "  ✅ 选路模式 → speed（无网络自动切换 + 网速优先）" \
                                  || echo "  ❌ 写 MODE 失败"
    # 4) Wi-Fi 自动寻找。默认关闭，因为"自动连别的 Wi-Fi"是有侵入性的
    # 动作（可能连到邻居的路由器），所以明确要求用户显式开启——这个命令
    # 就是显式开启的方式。
    conf_set_kv WIFI_FAILOVER 1 && echo "  ✅ Wi-Fi 自动寻找 → 开（当前 Wi-Fi 上不了网时试连其它已保存网络）" \
                                  || echo "  ❌ 写 WIFI_FAILOVER 失败"
    # 3) 双网并发。配置打开，但 pf 规则要 root 加载，分开说清楚。
    conf_set_kv BALANCE 1       && echo "  ✅ 双网并发 → 配置已开" \
                                  || echo "  ❌ 写 BALANCE 失败"
    conf_set_kv BALANCE_MODE weighted && echo "  ✅ 并发策略 → weighted（按实测吞吐自动配比）" \
                                  || echo "  ❌ 写 BALANCE_MODE 失败"

    echo ""
    if [ "$(id -u)" -eq 0 ]; then
        # root 直接加载，不用用户再敲一条
        if balance_on weighted; then
            echo "  ✅ pf 分流规则已加载"
        else
            echo "  ❌ pf 规则加载失败，请手动跑: sudo smartroute balance on weighted"
        fi
    else
        need_root=1
        echo "  ⚠️  还需要一条命令加载 pf 规则（要 root）："
        echo "      sudo smartroute balance on weighted"
    fi

    echo ""
    echo "接下来："
    if [ "$need_root" = "1" ]; then
        echo "  1. sudo smartroute balance on weighted   # 加载 pf 分流规则"
    fi
    echo "  2. smartroute status                      # 看当前选路和两条线状态"
    echo "  3. smartroute fetch <支持 Range 的大文件> -o out.bin -n 8"
    echo "     # 下载完看末尾的 per-interface 字节报告，两边都有量才算并发生效"
    echo ""
    echo "说明：-n 是连接数上限，工具会自适应扩连（先起 2 条，服务端扛得住才加）。"
    echo "      连接数不是越多越好，实测 n=4 是峰值，n=16 吞吐掉一半。"
    echo "      Cloudflare 的测速端点不认 Range，用它测会退化成单连接——换普通文件源。"
}

cmd_quality() {   # 每接口 6 个包测延迟/丢包（root 强制走该接口，非 root 只能测默认路由）
    local role dev svc gw out loss rtt min avg max rest via
    # 逐个接口加主机路由强制走指定网卡，同样要和守护进程的探测互斥
    acquire_lock_wait 10 || die "另一个 smartroute 操作正在进行（守护进程刚跑过一轮），请稍候再试"
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
    local TMP_ANCHOR=""
                     # $7=权重A $8=权重B（按容量重复网关，近似加权轮询；缺省 1:1）
    local d1="$1" gw1="$2" d2="$3" gw2="$4" excl="${5:-}" only="${6:-}"
    local wA="${7:-1}" wB="${8:-1}"
    # 权重必须落在 [1,8]。以前不校验，调用方传 0 或非数字时：
    #   · 0        → 那一侧的 while 循环一次都不跑，route-to 里没有它的条目，
    #                **一条线被完全饿死**，而函数返回 0、没有任何警告。
    #                用户看到的是"另一条线完全没流量"，却查不到原因。
    #   · 非数字   → [ "$_k" -lt "abc" ] 直接报错退出循环，同上。
    #   · 过大     → route-to 列表被撑爆，pfctl 加载变慢，配比也失去意义。
    # 上限 8 而不是 4：归一化在 balance_on 里已经收敛到 1..4，这里放宽一点
    # 只是防止调用方手滑，不影响正常路径。
    local _wi
    for _wi in wA wB; do
        local _wv="${!_wi}"
        case "$_wv" in
            ''|*[!0-9]*) eval "$_wi=1" ;;
            *) [ "$_wv" -ge 1 ] || eval "$_wi=1"; [ "$_wv" -le 8 ] || eval "$_wi=8" ;;
        esac
    done
    local lan1 lan2 same=0 list
    lan1="$(dev_subnet "$d1")"; lan2="$(dev_subnet "$d2")"
    if [ -n "$lan1" ] && [ "$lan1" = "$lan2" ]; then same=1; fi
    # fastest 模式：只把更快的那一个网关放进 route-to，其余流量不受影响
    if [ "$only" = "$d1" ]; then d2="$d1"; gw2="$gw1"; fi
    if [ "$only" = "$d2" ]; then d1="$d2"; gw1="$gw2"; fi
    mkdir -p "$(dirname "$PF_ANCHOR_FILE")" 2>/dev/null || return 1
    # 临时文件和最终文件同目录：mv 才是原子 rename，跨文件系统会退化成
    # 拷贝（非原子，中途失败会留下半套规则）
    TMP_ANCHOR="${PF_ANCHOR_FILE}.tmp.$$"
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
        elif [ "$wA" != "1" ] || [ "$wB" != "1" ]; then
            echo "# 策略: weighted ${wA}:${wB} —— 按实测吞吐配比分配新连接"
        else
            echo "# 策略: round-robin —— 新连接在两个接口间轮询"
        fi
        echo "ext1 = \"$d1\""
        echo "gw1  = \"$gw1\""
        echo "ext2 = \"$d2\""
        echo "gw2  = \"$gw2\""
        echo "table <lan_all> { $list }"
        # NAT 必须加，**同网段也要加**。
        #
        # 以前的判断是"同网段源地址天然合法，不需要 NAT"——这个判断是错的，
        # 而且错得正好把唯一的提速路径堵死：
        #
        #   内核按路由表给数据包选源地址。两个接口同网段时，去 192.168.1.1
        #   的路由只会指向其中一个接口（默认路由那个，en0），于是源地址
        #   固定是 en0 的 192.168.1.36。pf 的 route-to 只负责把包从 en1
        #   发出去，不改源地址。
        #
        #   结果是：包带着 en0 的 IP 从 Wi-Fi 出去，路由器按 ARP 表知道
        #   192.168.1.36 在有线口上，回程全部走有线。
        #
        #   对下载来说这致命——**下行永远走 100M 有线**，Wi-Fi 那 432M
        #   一点没用上。用户看到的现象就是"开了并发下载还是 100M"。
        #
        # 加了 nat on en1 -> (en1) 之后，源地址被改写成 en1 的 192.168.1.5，
        # 路由器据此把回程送到 Wi-Fi 口，下行才真正走 Wi-Fi。
        # NAT 的代价很小（一次地址改写），换来的是回程真的走对接口。
        echo "# 按出口接口修正源地址。同网段也必须做：内核选源地址只看路由表，"
        echo "# 同网段时永远选成默认路由那个接口的 IP；route-to 不改源地址，"
        echo "# 不回改的话回程会全部涌向另一个接口（下载就被钉死在慢的那条上）。"
        echo "# macOS 的 pf 不支持 match...nat-to，用经典 nat 规则；nat-anchor \"com.apple/*\" 覆盖本锚点"
        echo "nat on \$ext1 from ! <lan_all> to any -> (\$ext1)"
        [ "$d1" = "$d2" ] || echo "nat on \$ext2 from ! <lan_all> to any -> (\$ext2)"
        # 分流规则：fastest 模式收敛成单网关（round-robin 对单网关无意义）
        if [ "$d1" = "$d2" ]; then
            echo "pass out route-to { (\$ext1 \$gw1) } inet proto { tcp udp } from any to ! <lan_all>"
        else
            # 加权轮询：把快的网关按权重重复。pf 的 round-robin 只认列表顺序，
            # 重复条目是唯一能近似配比的写法（没有 weight 关键字可用）。
            local _rr="" _k=0
            _k=0; while [ "$_k" -lt "$wA" ]; do _rr="$_rr (\$ext1 \$gw1)"; _k=$((_k+1)); done
            _k=0; while [ "$_k" -lt "$wB" ]; do _rr="$_rr (\$ext2 \$gw2)"; _k=$((_k+1)); done
            _rr="${_rr# }"
            echo "pass out route-to { $_rr } round-robin inet proto { tcp udp } from any to ! <lan_all>"
        fi
        if [ -n "$excl" ]; then
            echo "# 已排除 VPN/拨号网段: $excl"
        fi
    } > "$TMP_ANCHOR" || { rm -f "$TMP_ANCHOR"; return 1; }
    # 自校验语法：pfctl 加载失败只报 "syntax error" 不给原因，先在这里挡一道。
    #
    # 必须先写临时文件、校验通过再 mv 落位，不能直接覆盖 ${PF_ANCHOR_FILE}。
    # 直接覆盖的问题是：校验失败时，磁盘上的 anchor 文件已经是被判非法的
    # 那一套，而内核里跑的却还是上一套好规则。于是
    #   · balance status 的"规则内容"把文件当生效内容打印 → 显示一套
    #     根本没跑的规则，用户照着排查完全偏离方向
    #   · 之后每次 pfctl -f 都继续失败
    #   · 最糟：如果有人（或系统）在那之后重新加载 pf，就会把非法规则
    #     装进内核，分流直接失效
    # 校验失败时保留旧文件不动，状态至少还是自洽的。
    if ! pfctl -n -f "$TMP_ANCHOR" >/dev/null 2>&1; then
        rm -f "$TMP_ANCHOR"
        return 1
    fi
    mv "$TMP_ANCHOR" "$PF_ANCHOR_FILE" || { rm -f "$TMP_ANCHOR"; return 1; }
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
    # 先写配置，再清规则。以前顺序相反，于是一个毫秒级窗口里：
    # 守护进程看到 anchor 已空、配置文件却还是 BALANCE=1 → 重新 pfctl -f
    # 加载 → 规则复活。最终状态是 pf 分流仍在生效，而配置说 0、
    # status 显示"未生成"——静默自相矛盾，且重启后才消失。
    # 配置也可能写不进去（root 建的 /Users/Shared/smartroute.conf 普通用户改不动）。
    # 这个返回值以前被丢掉了，于是配置没改成也报成功。
    if ! conf_set_auto BALANCE 0; then
        [ "$q" = "quiet" ] || echo "错误: 配置写不进去（BALANCE 仍是 1），守护进程可能会重新开启，未清规则" >&2
        return 1
    fi
    pfctl -a "$PF_ANCHOR" -F all 2>/dev/null
    rm -f "$PF_ANCHOR_FILE" 2>/dev/null
    if pf_enabled_by_us; then
        pfctl -d 2>/dev/null && log "双网并发: 关闭由 smartroute 开启的系统 pf"
    fi
    rm -f "$PF_STATE_FILE" 2>/dev/null
    # 分流相关的 state 必须一起清。以前不清，于是 off 之后 balance status
    # 同屏自相矛盾："BALANCE=0 / 规则未生成"，下面却还挂着
    # "分流策略: 按容量配比 1:4"——用户会以为关掉的只是规则、配比还在生效。
    state_set balance_mode ""
    state_set balance_winner ""
    state_set balance_weight ""
    log "双网并发分流已关闭，网络恢复原状"
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
        # 前 4 次全灭就别测剩下的了。pf 规则真把网络搞坏时，每次探测都要等满
        # nc 超时（NC_TIMEOUT 秒）+ 3 种兜底，10 次要 60-90 秒——用户看到的就是
        # "命令卡住"，然后按 Ctrl-C。早失败早还原，用户根本感觉不到卡过。
        # （Ctrl-C 现在也有 trap 兜底了，但能不让它发生更好。）
        if [ "$i" -eq 4 ] && [ "$ok" -eq 0 ]; then
            log "并发分流验证快速失败: 前 4 次探测全部超时，判定网络已不通"
            echo "验证快速失败：前 4 次探测全部超时，pf 规则可能影响了网络，已自动还原" >&2
            return 1
        fi
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
        # 只有"字节数 > 0"是不够的。Wi-Fi 只要关联着就永远有背景流量
        # （mDNS/ARP/DHCP/iCloud 心跳），实测几百字节起步。
        # 于是 pf route-to 根本没生效时，这一侧也"有流量"——验证通过、
        # 打出"✅ 已开启"，而用户拿着这份假证据去排查其他方向，
        # 比没有检查更糟。
        #
        # 两个条件同时满足才算这一侧真的在扛：
        #   · 绝对量够大：>= VALIDATE_MIN_BYTES（64KB）。
        #     10 个连通性探测本身就会产生远大于此的出站流量，
        #     所以真分流时轻松超过；纯背景心跳到不了。
        #   · 占比别太低：>= 10%。防止一侧扛了 4GB、另一侧 70KB
        #     这种"看起来分流了、其实全在一条线上"的情况。
        local bad_if="" bad_g=0 _tot=$(( g1 + g2 )) _min_pct=10
        local _p1=0 _p2=0
        [ "$_tot" -gt 0 ] && { _p1=$(( g1 * 100 / _tot )); _p2=$(( g2 * 100 / _tot )); }
        # 某一侧是否"真的在扛"
        _d1_ok() { [ "$g1" -ge "$VALIDATE_MIN_BYTES" ] && [ "$_p1" -ge "$_min_pct" ]; }
        _d2_ok() { [ "$g2" -ge "$VALIDATE_MIN_BYTES" ] && [ "$_p2" -ge "$_min_pct" ]; }
        if [ "$only" = "$d1" ]; then
            _d1_ok || { bad_if="$d1"; bad_g="$g1"; }
        elif [ "$only" = "$d2" ]; then
            _d2_ok || { bad_if="$d2"; bad_g="$g2"; }
        else
            if   ! _d1_ok && ! _d2_ok; then bad_if="$d1/$d2"; bad_g="$g1/$g2"
            elif ! _d1_ok; then bad_if="$d1"; bad_g="$g1"
            elif ! _d2_ok; then bad_if="$d2"; bad_g="$g2"; fi
        fi
        if [ -n "$bad_if" ]; then
            log "并发分流验证失败: 流量未走预期接口 ($bad_if +$bad_g 字节, $d1 +$g1 / $d2 +$g2)"
            echo "验证失败：流量没有走预期接口（$d1 +$g1 字节/${_p1}%，$d2 +$g2 字节/${_p2}%），已自动还原" >&2
            echo "         （判定标准：单侧至少 ${VALIDATE_MIN_BYTES} 字节且占比 ≥10%；" >&2
            echo "           低于此更可能是背景心跳，不是分流生效）" >&2
            echo "提示：本机 macOS 的 pf 可能未对出站流量生效 route-to。" >&2
            return 1
        fi
        log "并发分流验证通过: 连通性 $ok/10, 出站字节 $d1 +$g1 / $d2 +$g2${only:+ (只走 $only)}"
    else
        log "并发分流验证通过: 连通性 $ok/10（未能读取接口字节计数器，跳过分布检查）"
    fi
    return 0
}

# 重写 pf 规则前必须确认两个接口的网段都还能解析出来。
#
# 为什么 reevaluate 路径也需要这个守卫：dev_subnet 返回空的场景是真实存在
# 的（接口在 find_active 之后丢了 IPv4、DHCP 续租间隙、ifconfig 输出变化）。
# 此时生成的排除表会少一个 LAN，`to ! <lan_all>` 不再排除它，
# 于是**那个网段的流量被 NAT 到互联网——局域网静默不通**。
# balance_on 一直有这个检查，两个周期重测路径以前漏了：
# 守护进程跑几分钟后一旦踩到，用户家里所有内网设备互相不通，
# 而表面上只是"配比没更新"，没有任何报错。
# 宁可保留旧规则不重写，也不能生成一条会打死局域网的规则。
_balance_nets_ok() {   # $1=设备A $2=设备B，返回 0 表示可以安全重写
    local l1 l2
    l1="$(dev_subnet "$1")"; l2="$(dev_subnet "$2")"
    if [ -z "$l1" ] || [ -z "$l2" ]; then
        log "跳过规则重写: 无法确定接口网段 ($1=${l1:-未知} / $2=${l2:-未知})，保留现有规则"
        return 1
    fi
    return 0
}

# balance_on 被 Ctrl-C / kill 时的还原。单独定义而不是内联 trap 字符串：
# 内联的话引号嵌套能把人看疯，而且没法 echo 告知用户"正在还原"——
# 而那一句正是用户最需要看到的：他知道网络马上会回来。
_balance_on_interrupt() {
    echo "" >&2
    echo "已中断，正在还原 pf 规则（网络马上恢复）…" >&2
    balance_off quiet 2>/dev/null
    trap - INT TERM
    # 130 = 128 + SIGINT，是 shell 的约定退出码
    exit 130
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

    # 模式: balance on [round-robin|fastest|weighted] [--force]
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
        round-robin|rr|轮询)   mode="round-robin" ;;
        fastest|fast|最快)     mode="fastest" ;;
        weighted|weight|权重)  mode="weighted" ;;
        *) die "用法: smartroute balance on [round-robin|fastest|weighted] [--force]" ;;
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
    # 所以默认拒绝。--force 是逃生门，不是"验证一下"的推荐路径——
    local force=0 a2
    for a2 in "$@"; do
        case "$a2" in --force|-f) force=1 ;; esac
    done
    # 同网关一律拒绝，--force 也不再放行。
    #
    # 原来 --force 是逃生门，注释写的是"给想验证 pf 规则的人留口子"。
    # 但这条路实测走不通，而且是我们自己把用户引上去的：
    #   · 拒绝信息里印着"真要坚持强开，请先确认你还能再跑一次 balance off"
    #   · 用户照着这句去 --force
    #   · 然后网络卡死（回包走错接口被 pf 状态表丢弃），
    #     表现为网页打不开、一直转圈，只能自己想到 balance off 才恢复
    #   · 这个现象已经被报告过两次
    #
    # 而同网关下 pf 分流的收益是**实测为零**：瓶颈在路由器后面那条上游链路，
    # 不在入口。零收益 + 已证实的卡死风险，这个口子没有存在的理由。
    #
    # 想要两条线一起扛一个文件，用 smartroute fetch -n N：它显式把连接
    # 绑到各接口上，不依赖 pf，也没有这个卡死问题。
    if [ "$eth_gw" = "$wifi_gw" ]; then   # 与 eth_wifi_same_gateway 同一判据
        cat >&2 <<MSG
两个接口的网关相同（都是 ${eth_gw}），它们经同一台路由器上网——
这不是两条 WAN，而是一条 WAN 的两个入口。此时双网并发：
  · 不会变快：瓶颈在路由器后面的上游链路，不在入口
  · 反而更慢：一半连接会被赶到更慢的那个接口
  · 会让网页卡壳：pf 把连接轮流赶到两个接口，回包可能走错接口
    而被 pf 状态表丢弃——表现就是页面打不开、一直转圈，
    要跑 sudo smartroute balance off 才恢复

所以这个组合已禁用，--force 也不再放行（零收益 + 已证实的卡死风险）。

想要两条线一起扛一个文件，用：
  smartroute fetch <URL> -o out.bin -n 4
它显式把连接绑到各接口上，不依赖 pf 分流，也没有上面的卡死问题。

只想挑更快的那条线：用「选路模式 → 网速优先」。
MSG
        exit 1
    fi
    # --force 仍然从参数里摘掉（否则它会落进用法检查的 *) 分支被当成 mode，
    # 直接报"用法"错误——这个 bug 出过一次），但同网关下不再放行。
    if [ "$force" = "1" ]; then
        echo "(i) --force 在此版本已不改变同网关时的拒绝决定。"
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
    unset lan1 lan2

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

    # 【权重分流】实测两边吞吐，按容量分配新连接。
    #
    # 原来的 round-robin 是 1:1 盲分。可两条线 rarely 一样快——本机就是
    # 100M 有线配 432M Wi-Fi。1:1 平分意味着每边只拿到一半的连接，
    # 而快的那条（Wi-Fi）明明还能多扛，慢的那条（100M）却已经占满。
    # 总吞吐因此卡在慢的那条上，用户体验就是"并发也没变快"。
    #
    # 做法：把快的网关在 route-to 列表里重复多次，近似按容量配比。
    # pf 的 round-robin 只认列表顺序、不认权重，重复条目是最贴近的实现。
    local w1=1 w2=1 _bw0=""
    if [ "$mode" = "weighted" ]; then
        echo "正在测量两个接口的吞吐（各需一次下载，约几秒）…"
        local _t1 _t2 _n1 _n2 _g
        _t1="$(measure_throughput "$ACTIVE_ETH_DEV")"
        _t2="$(measure_throughput "$ACTIVE_WIFI_DEV")"
        printf "    %s: %s    %s: %s\n" "$ACTIVE_ETH_DEV" "$(fmt_bps "${_t1:-0}")" \
                                       "$ACTIVE_WIFI_DEV" "$(fmt_bps "${_t2:-0}")"
        if [ -n "$_t1" ] && [ -n "$_t2" ] && [ "$_t1" -gt 0 ] 2>/dev/null && [ "$_t2" -gt 0 ] 2>/dev/null; then
            # 归一化到 1..4：快的一边定为 4，另一边按比例取整（至少 1）。
            # 不引入 gcd——比例取整到 4 档已经够用，多一个helper不划算。
            # 上限 4 也防止快的那条把慢的饿死（慢的那条仍能分担，真出事时是备份）。
            if [ "$_t1" -ge "$_t2" ]; then
                w1=4; w2=$(( _t2 * 4 / _t1 )); [ "$w2" -lt 1 ] && w2=1
            else
                w2=4; w1=$(( _t1 * 4 / _t2 )); [ "$w1" -lt 1 ] && w1=1
            fi
            echo "    → 按容量配比：以太网 x$w1 / Wi-Fi x$w2"
            # 测到了才记配比。回退成轮询时不记——否则 status 会显示一个
            # 实际没生效的配比，比不显示更糟。
            _bw0="$w1:$w2"
        else
            echo "    ⚠️  至少一边测不到吞吐，回退为 1:1 轮询"
            w1=1; w2=1; mode="round-robin"
        fi
    fi

    # ── 中断保护：从加载 pf 这一刻起，任何 Ctrl-C / kill 都必须先还原 ──
    #
    # 实测过的故障链（用户报"开启双网并发后网络卡死"）：
    #   1. pf 规则加载，网络被规则搞坏
    #   2. balance_validate 跑 10 次 nc，每次超时 2 秒、还有 3 种兜底，
    #      全灭时要 60-90 秒——用户看到的就是"命令卡住"
    #   3. 用户按 Ctrl-C
    #   4. **没有 trap**，pf 规则留在系统里，网络继续卡着
    #   5. 用户自己想到 balance off 才恢复
    #
    # 日志完全对得上：既没有"验证失败"也没有"已开启"，但 pf 确实是
    # smartroute 开的。第 4 步是纯粹的可避免故障——用户正是指望这个命令
    # 救他，却不能靠它自救。
    trap '_balance_on_interrupt' INT TERM
    echo "生成分流规则: $ACTIVE_ETH_DEV($lan1, gw $eth_gw) <-> $ACTIVE_WIFI_DEV($lan2, gw $wifi_gw) [$mode]"
    write_pf_rules "$ACTIVE_ETH_DEV" "$eth_gw" "$ACTIVE_WIFI_DEV" "$wifi_gw" "$excl" "$only" "$w1" "$w2" \
        || { trap - INT TERM; die "无法写入 $PF_ANCHOR_FILE"; }

    # 记录系统 pf 原状态，便于撤销时还原
    if pf_enabled; then
        echo "pf_enabled_by_us=0" > "$PF_STATE_FILE" 2>/dev/null
    else
        pfctl -e 2>/dev/null
        echo "pf_enabled_by_us=1" > "$PF_STATE_FILE" 2>/dev/null
        log "双网并发: 系统 pf 原为关闭，已由 smartroute 开启（撤销时会关闭）"
    fi
    pfctl -a "$PF_ANCHOR" -f "$PF_ANCHOR_FILE" 2>/dev/null \
        || { trap - INT TERM; balance_off quiet; die "加载 pf 规则失败，已还原"; }
    # 关键校验：规则"加载成功"不等于"生效"。锚点若没被主规则集引用，
    # pfctl 照样返回 0，但流量永远不会匹配。这里必须回读确认规则真的在规则集里。
    if ! pfctl -a "$PF_ANCHOR" -s rules 2>/dev/null | grep -q "route-to"; then
        trap - INT TERM; balance_off quiet
        die "pf 锚点 $PF_ANCHOR 未生效（未被主规则集引用），已还原；请检查 /etc/pf.conf 是否包含 anchor \"com.apple/*\""
    fi

    echo "正在验证分流效果（10 个测试连接）…"
    if ! balance_validate "$ACTIVE_ETH_DEV" "$(dev_ipv4 "$ACTIVE_ETH_DEV")" \
                         "$ACTIVE_WIFI_DEV" "$(dev_ipv4 "$ACTIVE_WIFI_DEV")" "$only"; then
        trap - INT TERM; balance_off quiet
        die "并发分流未通过验证，已自动还原（详见 sudo smartroute log）"
    fi

    # 返回值必须检查。以前两个都被丢掉，于是配置没落盘也照样打印
    # "✅ 双网并发已开启"。而 BALANCE=1 没写进去的后果是：
    # 重启或重载配置后，守护进程的并发安全阀、weighted/fastest 重测
    # 全部静默停摆——用户以为并发开着，实际上只剩启动时那一套
    # pf 规则在跑，接口挂了也不会自动关。
    # /Users/Shared/smartroute.conf 属 root 时普通用户改不动，
    # 这个场景在 wifi auto 分支（3510-3526）和 balance_off 里都处理了，
    # 这里以前漏掉。
    if ! conf_set_auto BALANCE 1; then
        trap - INT TERM; balance_off quiet
        die "pf 规则已装好，但配置写不进去（BALANCE 没设成 1），守护进程不会维护它。\
            通常是 /Users/Shared/smartroute.conf 属主不对，请执行:\
            sudo chown \$(id -un):staff /Users/Shared/smartroute.conf && sudo smartroute balance on"
    fi
    if ! conf_set_auto BALANCE_MODE "$mode"; then
        trap - INT TERM; balance_off quiet
        die "pf 规则已装好，但 BALANCE_MODE 没写进配置，重启后会回落到 round-robin。\
            通常是 /Users/Shared/smartroute.conf 属主不对，请执行:\
            sudo chown \$(id -un):staff /Users/Shared/smartroute.conf && sudo smartroute balance on"
    fi
    state_set balance_mode "$mode"
    # weighted 一开启就把当前配比写进 state。以前不写，刚开完时
    # balance status 显示"按容量配比（等待守护进程重测后显示）"，
    # 而规则里其实已经是 1:4 了——用户看到的和实际生效的不一致，
    # 而且这一等就是 10 分钟。
    if [ "$mode" = "weighted" ] && [ -n "${_bw0:-}" ]; then
        state_set balance_weight "$_bw0"
    fi
    state_set balance_winner "$only"
    trap - INT TERM
    log "双网并发分流已开启: $ACTIVE_ETH_DEV <-> $ACTIVE_WIFI_DEV 模式=$mode${only:+ 最快=$only}"
    echo
    if [ "$mode" = "fastest" ]; then
        echo "✅ 双网并发已开启（最快线路模式）：新连接全部走 $only"
        echo "   • 守护进程每隔约 $((FASTEST_RECHECK * 20 / 60)) 分钟重测延迟，线路变慢会自动改走另一条"
    else
        echo "✅ 双网并发已开启（${mode}）：新连接会按容量分摊到两个接口"
        echo "   • 多连接/多应用（浏览、下载、云同步）能叠加两条线的带宽"
        if [ "$w1" != "1" ] || [ "$w2" != "1" ]; then
            echo "   • 本次配比 以太网 x$w1 : Wi-Fi x$w2 —— 按实测吞吐，慢的那条不会先被占满"
        fi
        # 这句话必须说清楚。用户问"两个网络一起跑一个数据"——IP 路由做不到：
        # pf 按连接（状态）选路，一个 TCP 连接从头到尾只用一条线。
        # 一条流跨两条线需要 MPTCP，macOS 不支持。含糊其辞比直说更糟，
        # 因为用户会以为是工具没做到，反复重装。
        echo "   • 单线程下载不会翻倍：一个连接固定走一个接口（IP 路由的硬限制，"
        echo "     要一条流跨两条线需要 MPTCP，macOS 不支持）"
    fi
    echo "   • 任一口失去外网会自动关闭并发并还原（见守护进程安全阀）"
    echo "   • 撤销: sudo smartroute balance off"
    return 0
}

cmd_balance() {
    local arg="${1:-status}"
    case "$arg" in
        on|enable|start)  shift; balance_on "$@" ;;
        # off 也要拿锁。balance_on 走 acquire_lock_strict，off 以前不走，
        # 于是 off 和一个 watch 周期撞上时（毫秒级窗口）：
        # 守护进程看到 anchor 空、文件还在 → 重新 pfctl -f 加载 → 规则复活。
        # 最终状态：pf 分流仍在生效，而配置 BALANCE=0、status 显示"未生成"
        # ——静默自相矛盾，且重启后才消失。
        off|disable|stop)
            if [ "$(id -u)" -eq 0 ]; then
                acquire_lock_strict || die "拿不到操作锁，请稍后重试"
            fi
            balance_off ;;
        status|st)        balance_status ;;
        *) die "用法: smartroute balance on [round-robin|fastest|weighted] | off | status" ;;
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
    # 网段守卫：见 _balance_nets_ok 的注释。fastest 重测以前漏了这个检查，
    # 一旦 dev_subnet 返回空就生成少一个 LAN 的排除表，
    # 那个网段的流量会被 NAT 到互联网——局域网静默不通。
    _balance_nets_ok "$ACTIVE_ETH_DEV" "$ACTIVE_WIFI_DEV" || return 0
    write_pf_rules "$ACTIVE_ETH_DEV" "$eth_gw" "$ACTIVE_WIFI_DEV" "$wifi_gw" "$excl" "$want" || return 1
    pfctl -e 2>/dev/null
    pfctl -a "$PF_ANCHOR" -f "$PF_ANCHOR_FILE" 2>/dev/null || return 1
    # ⚠️ 已知缺口（不要假装这里没有）：改写规则后**没有**做 balance_validate。
    # balance_on 有，这两条重测路径没有。想过加上，实测不可行：
    #   · 代价：10 个探测，快几秒慢几十秒，而守护进程这条路径每轮都跑
    #   · 误伤：单次网络抖动就可能把用户的双网并发永久关掉，太鲁莽
    #     （balance_off 会把 BALANCE 置 0，守护进程不会自己开回来）
    #   · 测不了：mock_fastest.sh 没有 netstat mock，validate 读真实计数器，
    #     而 mock 的 nc 不产生真实流量，验证必然失败——7 条断言假失败
    # 现在的兜底只有两道：cmd_watch 的"任一口没外网就关"安全阀，
    # 和规则丢失重载。真要补，应该先给这两条路径加 netstat mock。
    state_set balance_winner "$want"
    notify "SmartRoute 网速优先" "已切换到更快的线路：$(dev_cn "${want:-}")（两条线路轮流用）"
    return 0
}

# weighted 模式的周期性重测。
#
# 为什么要重测：权重是在 balance on 那一刻算的，之后永不更新。可 Wi-Fi 的
# 实际吞吐一直在变（走远一点、信道拥塞、邻居开机），几分钟后 1:4 就失真了。
# 失真的后果很直接：如果 Wi-Fi 掉到比有线还慢，4/5 的新连接还在往 Wi-Fi 送，
# 总吞吐反而低于单走有线——"开了并发比不开还慢"。
#
# 只在**权重真的变了**时才重写 pf 规则。pfctl -f 会重建整张 anchor，
# 正在跑的连接不断（pf 是有状态的，规则重载不影响已有 state），但没必要
# 每次轮询都重载一遍；而且只有变化才值得通知用户。
balance_weight_reevaluate() {
    local eth_gw wifi_gw t1 t2 w1 w2 cur excl
    eth_gw="$(svc_router "$ACTIVE_ETH_SVC")"; wifi_gw="$(svc_router "$ACTIVE_WIFI_SVC")"
    [ -n "$eth_gw" ] && [ -n "$wifi_gw" ] || return 0
    # 复用缓存：ensure_throughput 内部按 SPEED_RECHECK 判断新鲜度，
    # 不会每个轮询都真下载一次。force 传空就是不强制。
    ensure_throughput "$ACTIVE_ETH_DEV" "$ACTIVE_WIFI_DEV" || return 0
    # 必须用 _metric_val，不能用 state_get：_metric_set 存的是"值 时间戳"，
    # state_get 原样返回、带着空格。用 state_get 会让下面两道校验全落空
    # （空格命中 *[!0-9]*），于是**永远不重写**——重测功能静默失效，
    # 而表面上只是"配比没更新"，没有任何报错。
    # _metric_val 负责去掉时间戳，非数字/非正数一律返回空。
    t1="$(_metric_val "speed_$ACTIVE_ETH_DEV")"
    t2="$(_metric_val "speed_$ACTIVE_WIFI_DEV")"
    [ -n "$t1" ] && [ -n "$t2" ] || return 0
    [ "$t1" -gt 0 ] && [ "$t2" -gt 0 ] || return 0

    # 归一化到 1..4：与 balance_on 保持同一套算法，否则用户看到的配比
    # 会和实际生效的不一致。上限 4 也防止快的那条把慢的饿死。
    if [ "$t1" -ge "$t2" ]; then
        w1=4; w2=$(( t2 * 4 / t1 )); [ "$w2" -lt 1 ] && w2=1
    else
        w2=4; w1=$(( t1 * 4 / t2 )); [ "$w1" -lt 1 ] && w1=1
    fi
    cur="$(state_get balance_weight)"
    [ "$cur" = "$w1:$w2" ] && return 0

    log "权重重测: $ACTIVE_ETH_DEV=$(fmt_bps "$t1") / $ACTIVE_WIFI_DEV=$(fmt_bps "$t2") → ${w1}:${w2}（原 ${cur:-未记录}）"
    excl="$(other_nets | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    # 注意不要传 same：write_pf_rules 自己用 dev_subnet 算，只收 8 个参数。
    # 多传不会报错，但会让人以为要在这里维护它——改子网判断时就会漏改。
    _balance_nets_ok "$ACTIVE_ETH_DEV" "$ACTIVE_WIFI_DEV" || return 0
    write_pf_rules "$ACTIVE_ETH_DEV" "$eth_gw" "$ACTIVE_WIFI_DEV" "$wifi_gw" "$excl" "" "$w1" "$w2" || return 1
    pfctl -e 2>/dev/null
    pfctl -a "$PF_ANCHOR" -f "$PF_ANCHOR_FILE" 2>/dev/null || return 1
    state_set balance_weight "$w1:$w2"
    notify "SmartRoute 并发配比已更新" "以太网 x${w1} / Wi-Fi x${w2}（按实测吞吐自动调整）"
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
        echo "     （强开有网络卡死风险，不建议；见 balance on 的提示）"
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
    elif [ "$bmode" = "weighted" ]; then
        # 配比必须打出来。以前只打"轮询（两个接口交替）"，而 weighted 根本不
        # 是轮询——它按实测吞吐把快的网关在 route-to 列表里重复多次。
        # 显示成"轮询"会让用户以为两边一样多，实际可能是 1:4，
        # 排查时完全对不上。而且配比是周期重测的，用户需要看到当前值。
        local _bw
        _bw="$(state_get balance_weight)"
        if [ -n "$_bw" ]; then
            echo "  分流策略       : 按容量配比 ${_bw}（以太网 x${_bw%%:*} / Wi-Fi x${_bw##*:}）"
        else
            echo "  分流策略       : 按容量配比（等待守护进程重测后显示）"
        fi
    else
        echo "  分流策略       : 轮询（两个接口交替）"
    fi
    # 实时测一次两边延迟，方便判断"哪条更快"
    if [ -n "$ACTIVE_ETH_DEV" ] || true; then :; fi
    find_active >/dev/null 2>&1
    if [ -n "$ACTIVE_ETH_DEV" ] && [ -n "$ACTIVE_WIFI_DEV" ]; then
        local eg wg el wl
        eg="$(svc_router "$ACTIVE_ETH_SVC")"; wg="$(svc_router "$ACTIVE_WIFI_SVC")"
        # 必须拿锁。measure_latency 在 root 下会先 cleanup_probe_routes
        # 再加主机路由，而守护进程每 20 秒也在做同样的事。两边撞上时：
        #   · status 显示的是错延迟（自己的探测路由被删，流量改走默认路由）
        #   · 更糟——status 的 cleanup 会把守护进程刚加的探测路由删掉，
        #     守护进程于是"测了另一个接口"，可能触发一次本不该发生的切换。
        # acquire_lock_wait 的注释描述的就是这个事故。
        # 非 root 时快速放行（没有锁文件可拿，也不该为看状态卡住）。
        if [ "$(id -u)" -eq 0 ]; then
            acquire_lock_wait || echo "  （守护进程正在操作，本次不测实时延迟）"
        fi
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
    elif [ "$bmode" = "weighted" ]; then
        echo "  原理: 按实测吞吐把快的网关在 route-to 列表里重复多次，近似加权轮询"
        echo "        守护进程约每 10 分钟重测一次，Wi-Fi 变慢会自动把配比调回来"
        echo "        （否则会出现'开了并发比不开还慢'）"
    else
        echo "  原理: 新连接按轮询在两个网关间分流（不同连接走不同接口）"
    fi
    echo "  限制: 单线程传输不会加速；IPv6 流量不受影响；VPN 默认路由下不可用"
    return 0
}

[ "$(uname -s)" = "Darwin" ] || die "本工具仅支持 macOS"

# 退出时的清理必须**有条件**，不能无条件做两件事。
#
# 以前是无条件 cleanup_probe_routes + rm -rf "$LOCK_DIR"，于是任何一条
# root 命令退出都会踩到正在运行的守护进程：
#   · sudo smartroute status / test / doctor / report / balance status
#   · acquire_lock 抢不到锁时的 exit 0
# 这些进程根本没加过探测路由、也没持锁，退出时却把守护进程的锁删了、
# 把探测途中的主机路由删了。后果是锁形同虚设：随后并发的 watch 互相
# 加/删同一批 /32 路由，探测走了默认路由（也就是测了另一个接口），
# 可能把默认路由切到没有外网的口。
# /var/run 是 root:daemon 组可写——非 root 删不动，root 一删就中，
# 而本机守护进程是常驻的，这个场景现实存在。
#
# 两条判据分开：
#   PROBE_ROUTES_ADDED —— 本次进程真加过探测路由才准清。
#                          由 route_add_host 成功时置 1（见该函数）。
#   LOCK_HELD           —— 本次进程真拿到锁才准删锁目录。
#                           由 _lock_try 成功时置 1。
# 两个变量在脚本执行期始终存在（非 root 下不会拿到锁、也不会加路由，
# 两个都是 0，清理自然不发生），所以不用 set -u 也能安全引用。
_smartroute_cleanup() {
    [ "${PROBE_ROUTES_ADDED:-0}" = "1" ] && cleanup_probe_routes >/dev/null 2>&1
    [ "${LOCK_HELD:-0}" = "1" ] && rm -rf "$LOCK_DIR" 2>/dev/null
    return 0
}
trap '_smartroute_cleanup' EXIT INT TERM HUP

# 返回 0=拿到锁，1=被别人占着。三种抢锁方式都基于它，
# 避免"退出码语义"在三个函数里各写一遍、各自漂移。
_lock_try() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        LOCK_HELD=1          # 见下面 EXIT trap 的注释：只有真持锁才准删
        return 0
    fi
    local pid
    pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    # 持有者已死（上次被 SIGKILL）：清残留再试
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        LOCK_HELD=1
        return 0
    fi
    return 1
}

acquire_lock() {
    _lock_try || exit 0   # 守护进程：安静跳过这一轮，下次再来
}

# 带等待的抢锁，给交互命令用（measure now / quality / test）。
#
# 为什么需要它：这三个命令都会加/删主机路由（measure_latency 和 probe_dev
# 动的是同一批目标），而守护进程每 20 秒也在动同一批路由。两个进程并发时，
# 一方的 cleanup_probe_routes 会把另一方刚加的路由删掉——于是探测或测延迟
# 走了默认路由，也就是**测了另一个接口**。测错的直接后果是错误的可用性判定，
# 进而触发一次本来不该发生的切换。
#
# 为什么不用 acquire_lock_strict（忙就报错）：这些命令常由 App 触发，
# 而守护进程每 20 秒占锁几秒，撞上的概率很高，每次都报错体验很差。
# 所以等一小会儿；等不到就明说，不要硬闯。
acquire_lock_wait() {   # $1=最多等待秒数（默认 8）
    # 非 root 且锁目录还不存在：直接放行，不要等。
    #
    # 锁目录在 /var/run 下，属 root。非 root 用户**建不出**这个目录，
    # 于是 _lock_try 永远失败、白等满超时、最后报"另一个操作正在进行"——
    # 而真相是根本没有锁可用。这会把 App 的体检/测延迟页整个打死
    # （App 调 quality 不带 sudo）。
    #
    # 而互斥的目的只是保护主机路由的增删，那件事本身就需要 root：
    # probe_dev / measure_latency / cmd_quality 在非 root 下都走
    # "按当前默认路由"的分支，根本不碰路由表，没有东西需要互斥。
    # 所以非 root 放行是安全的，不是"放弃保护"。
    if [ ! -d "$LOCK_DIR" ] && [ "$(id -u)" -ne 0 ]; then
        return 0
    fi
    local deadline=$(( $(date +%s) + ${1:-8} ))
    while :; do
        _lock_try && return 0
        [ "$(date +%s)" -ge "$deadline" ] && return 1
        sleep 0.5
    done
}

# 严格版抢锁：被其他实例占用时不静默退出，而是报错（供 balance 这类交互命令用）
acquire_lock_strict() {
    _lock_try || die "另一个 smartroute 正在运行（锁: ${LOCK_DIR}），请等它结束再试"
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
#
# 两个必须的守卫，少一个就会把失败伪装成数据：
# 1) 设备为空时 networksetup 把错误文本写到 **stdout** 并返回 10，
#    sed -n '2,$p' 恰好留下第二行 "** Error: Error obtaining wireless
#    information." —— 于是一条幽灵 SSID 出现在 wifi list、report 和
#    App 的 Wi-Fi 页里，而且** 在 `for ssid in $saved` 里会被 glob
#    展开成目录清单。
# 2) 即使设备非空，接口被禁用/无 IPv4 时 find_active 也不会给它
#    ACTIVE_WIFI_DEV（它只收有 IPv4 的设备），所以第 1 条是常态而非边角。
#
# 最后一级仍用 sed 而不是 grep -v：这样即使全部被滤掉、输出为空，
# 管道退出码仍是 0，不改变现有 6 个调用点的成败语义。
wifi_saved_list() {
    [ -n "${ACTIVE_WIFI_DEV:-}" ] || return 1
    networksetup -listpreferredwirelessnetworks "$ACTIVE_WIFI_DEV" 2>/dev/null \
        | sed -n '2,$p' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -v '^$' | sed '/^\*\*/d; / is not a /d'
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
    # stdout 只有网络行，不带统计。这个契约被 tests/mock_wifi_scan.sh 锁定
    # （整串相等比较），不能往里加 @unknown 行。
    # 需要 unknown 数量的调用方见 wifi_nearby——它不走命令替换，
    # 所以能直接读到 WIFI_SCAN_UNKNOWN。
}

# 附近有信号的已保存网络（按信号排序）。-> stdout: "SSID rssi channel"，
# 末行 "@unknown N" 是有几个网络没能确认在不在范围（由 wifi_scan 透传）。
#
# 为什么要把 unknown 打到 stdout：调用方是 near="$(wifi_nearby ...)"，
# 命令替换在子 shell 里跑，函数内对 WIFI_SCAN_UNKNOWN 的累加父进程收不到。
# 于是"有 N 个没能确认（系统扫描冷却，不是故障）"这句提示从不出现，
# 用户以为全查过了——而快速扫描模式下恰恰是大部分没确认。
wifi_nearby() {
    # 末行 "@unknown N" 是有几个网络没能确认在不在范围。
    #
    # 为什么必须绕开命令替换：wifi_scan 在子 shell 里累加 WIFI_SCAN_UNKNOWN，
    # near="$(wifi_scan ...)" 这种写法父进程收不到。但不能把统计塞进
    # wifi_scan 的 stdout——它的契约是"只有网络行"（既有测试整串比较）。
    # 所以这里把 wifi_scan 的输出重定向到临时文件：不用子 shell，
    # WIFI_SCAN_UNKNOWN 在同一个 shell 里累加，读完再打出来。
    local _f _rc
    _f="$(mktemp "${TMPDIR:-/tmp}/sr_nearby.XXXXXX")" || return 1
    wifi_scan "$(wifi_saved_list | tr '\n' ' ')" "${1:-0}" >"$_f" 2>/dev/null
    _rc=$?
    [ -s "$_f" ] && cat "$_f"
    printf '@unknown %s\n' "${WIFI_SCAN_UNKNOWN:-0}"
    rm -f "$_f"
    return $_rc
}

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

# stdout 契约：**只有**成功的 SSID（没有就空）。tests/mock_wifi.sh 依赖这个。
# 失败汇总走 WIFI_TRY_STATS_FILE 指向的临时文件（见函数末尾）——
# 因为调用方是 got="$(wifi_try_candidates ...)"，命令替换在子 shell 里跑，
# 函数内对 WIFI_TRY_TOTAL 等的赋值父进程收不到，直接设变量会让汇总永远
# 显示"试了 个"、三个分类全空，[ "" -gt 0 ] 还抛 stderr。
# 而把统计打到 stdout 又会破坏上面那个契约，所以用文件。
wifi_try_candidates() {   # $1=候选列表 $2=每个等几秒 -> stdout: 成功的 SSID 或空
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
    # 统计写到一个文件里，由调用方读。不能打到 stdout——本函数的契约是
    # "stdout 只有成功的 SSID"（tests/mock_wifi.sh 第 5 节整串判空，
    # 加了统计行就永远不为空）；也不能只设 WIFI_TRY_* 变量——调用方是
    # got="$(wifi_try_candidates ...)"，命令替换在子 shell 里跑，父进程
    # 收不到，于是失败汇总永远显示"试了 个"、三个分类全是空的。
    # 临时文件是唯一两条都满足的通道。
    if [ -n "${WIFI_TRY_STATS_FILE:-}" ]; then
        printf 'total=%s oor=%s ni=%s jf=%s\n' \
            "$WIFI_TRY_TOTAL" "$WIFI_TRY_OUTOFRANGE" "$WIFI_TRY_NOINET" "$WIFI_TRY_JOINFAIL" \
            >"$WIFI_TRY_STATS_FILE" 2>/dev/null
    fi
    return 1
}

# 读 wifi_try_candidates 写进临时文件的统计。
# 为什么用文件而不是变量/stdout：调用方是 got="$(wifi_try_candidates ...)"，
# 命令替换在子 shell 里跑，函数内设的 WIFI_TRY_* 变量父进程收不到（于是
# 失败汇总永远显示"试了 个"、三个分类全空）；而统计也不能打进 stdout——
# 那会破坏"stdout 只有 SSID"的契约（tests/mock_wifi.sh 第 5 节整串判空）。
# 文件是唯一两条都满足的通道。
wifi_try_read_stats() {   # $1=统计文件路径 -> 设置 _WT_TOTAL/_WT_OOR/_WT_NI/_WT_JF
    local st=""
    [ -n "${1:-}" ] && [ -f "$1" ] && st="$(cat "$1" 2>/dev/null)"
    _WT_TOTAL=0; _WT_OOR=0; _WT_NI=0; _WT_JF=0
    [ -n "$st" ] || return 0
    local kv
    for kv in $st; do
        case "$kv" in
            total=*) _WT_TOTAL="${kv#total=}" ;;
            oor=*)   _WT_OOR="${kv#oor=}" ;;
            ni=*)    _WT_NI="${kv#ni=}" ;;
            jf=*)    _WT_JF="${kv#jf=}" ;;
        esac
    done
    # 空值和脏值都必须归零。空串拼起来还是空串，匹配不上 *[!0-9]*，
    # 所以下面先逐项判空——否则 "total=" 这种会让
    # [ "" -gt 0 ] 抛 integer expression expected，正是要消除的那类 stderr。
    local _v _x
    for _v in _WT_TOTAL _WT_OOR _WT_NI _WT_JF; do
        eval "_x=\${$_v}"
        case "$_x" in ''|*[!0-9]*) eval "$_v=0" ;; esac
    done
    return 0
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
    local got _sf
    _sf="$(mktemp "${TMPDIR:-/tmp}/sr_wts.XXXXXX")" || _sf=""
    WIFI_TRY_STATS_FILE="$_sf"
    got="$(wifi_try_candidates "$(wifi_preferred_candidates)" 6)"
    WIFI_TRY_STATS_FILE=""
    wifi_try_read_stats "$_sf"
    [ -n "$_sf" ] && rm -f "$_sf"
    if [ -n "$got" ]; then
        log "Wi-Fi 故障转移成功：已切到 ${got}（试了 ${_WT_TOTAL} 个）"
        notify "smartroute" "已自动切换到可用 Wi-Fi：${got}"
    else
        # 汇总必须带原因分类。全是"不在范围"说明旁边就没那些路由器，
        # 是环境问题；有"连不上"才可能是密码改了——两者的处理完全不同。
        log "Wi-Fi 故障转移：已保存的 Wi-Fi 都没有外网，放弃本轮（试了 ${_WT_TOTAL} 个：不在范围 ${_WT_OOR}、拿到 IP 但没外网 ${_WT_NI}、连不上 ${_WT_JF}）"
        if [ "${_WT_TOTAL:-0}" -gt 0 ]; then
            echo "试连了 ${_WT_TOTAL} 个已保存网络：不在范围 ${_WT_OOR} 个、连上但没外网 ${_WT_NI} 个、连不上 ${_WT_JF} 个"
            [ "${_WT_JF:-0}" -gt 0 ] && echo "  有网络连不上——可能是密码改了，或信号太弱"
        fi
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
            # 测速会加/删主机路由，必须和守护进程的探测互斥——
            # 否则两方互相删对方刚加的路由，测到的是另一个接口的数据，
            # 进而让 speed/latency 模式做出错误的切换决策。
            acquire_lock_wait 10 || die "另一个 smartroute 操作正在进行（守护进程刚跑过一轮），请稍候再试"
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
            else
                # 跳过时必须说为什么。以前直接跳到 cmd_measurements，
                # 打出四行"未测"就结束——App 的"立即测速"按钮看起来坏了，
                # 而实际只是守护进程还没判定接口可用（或接口不在线）。
                # 用户没法从输出里区分"工具坏了"和"接口没就绪"。
                local _why=""
                [ -z "$ACTIVE_ETH_DEV" ]  && _why="${_why}没检测到活跃以太网接口；"
                [ -z "$ACTIVE_WIFI_DEV" ] && _why="${_why}没检测到活跃 Wi-Fi 接口；"
                [ "$(state_get eth_ok)"  != "1" ] && _why="${_why}守护进程判定以太网当前不可用；"
                [ "$(state_get wifi_ok)" != "1" ] && _why="${_why}守护进程判定 Wi-Fi 当前不可用；"
                echo "跳过测速：${_why:-接口状态未就绪}"
                echo "（等守护进程跑过一轮、或确认两个接口都在线后再试）"
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
                # 空设备时安静返回：App 侧 Shell.run 会把 stderr 并进 stdout，
                # 在这里 die 等于把错误文本又当成一条 SSID 显示——换了一种说谎方式。
                [ -n "$ACTIVE_WIFI_DEV" ] || return 0
                wifi_saved_list
                return 0
            fi
            # 人读格式：没有 Wi-Fi 接口要明说，和 scan/join/tryall 的措辞一致
            [ -n "$ACTIVE_WIFI_DEV" ] || { echo "没有检测到 Wi-Fi 接口"; return 1; }
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
            local near all far="" s rssi ch nunknown=0
            near="$(wifi_nearby "$_thorough")"
            all="$(wifi_saved_list | tr '\n' ' ')"
            # @unknown 那行是统计，不能当网络名去打。剥离它并取出数量：
            # 不剥离的话会显示成一个名为 "@unknown 3" 的网络。
            nunknown="$(printf '%s\n' "$near" | sed -n 's/^@unknown //p' | tail -1)"
            near="$(printf '%s\n' "$near" | sed '/^@unknown /d' | sed '/^$/d')"
            case "${nunknown:-}" in ''|*[!0-9]*) nunknown=0 ;; esac

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
            # 有几个没能确认必须说。快速扫描模式（--quick）下大部分网络
            # 都来不及确认，不说的话用户以为全查过了，会怀疑扫描坏了。
            if [ "$nunknown" -gt 0 ]; then
                echo
                echo "（有 $nunknown 个已保存网络没能确认在不在范围——系统扫描有冷却，不是故障；加 --quick 更快但确认得更少）"
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
            local got ordered _sf
            ordered="$(wifi_rank_candidates "$(wifi_saved_list | tr '\n' ' ')")"
            _sf="$(mktemp "${TMPDIR:-/tmp}/sr_wts.XXXXXX")" || _sf=""
            WIFI_TRY_STATS_FILE="$_sf"
            got="$(wifi_try_candidates "$ordered" 6)"
            WIFI_TRY_STATS_FILE=""
            wifi_try_read_stats "$_sf"
            [ -n "$_sf" ] && rm -f "$_sf"
            if [ -n "$got" ]; then
                echo "✅ 找到可用的网络：$got"
                [ "$NOTIFY" = "1" ] && notify "SmartRoute" "已切换到可用 Wi-Fi：$got"
                return 0
            fi

            # 失败要把原因说清楚。原来一律报"都没有外网"，
            # 但绝大多数是"不在范围"（旁边没这个路由器），那是正常的；
            # 真正值得用户处理的是"找到了却连不上"。
            echo "❌ 没找到能上网的网络。试了 ${_WT_TOTAL} 个："
            [ "${_WT_OOR}" -gt 0 ] && echo "   · ${_WT_OOR} 个不在范围（旁边没有这个路由器，属正常）"
            [ "${_WT_JF}" -gt 0 ] && echo "   · ${_WT_JF} 个找到了但连不上（密码可能改过了）"
            [ "${_WT_NI}" -gt 0 ] && echo "   · ${_WT_NI} 个能连上但没有外网（可能要网页认证）"
            if [ "${_WT_JF}" -gt 0 ]; then
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

    # ── 按列表逐个试，第一个测出非零速度的源胜出 ──
    # 单个源不可用时整体测速失败，"网速优先"模式会静默失灵，
    # 而用户看不出是源坏了还是线坏了。
    #
    # 优先级：用户在配置文件里显式设了 SPEED_TEST_URL（单值）时，只用它那一个。
    # 否则会用脚本默认的 SPEED_TEST_URLS 列表——而那个默认值始终非空，
    # 于是 "${SPEED_TEST_URLS:-$SPEED_TEST_URL}" 永远取到列表，
    # **用户设的单值被静默忽略**。他改了配置、重启守护进程、
    # 发现测速结果毫无变化，会以为工具没生效。
    # 判据用 _conf_set 记录"这个键是不是用户配的"，而不是比较字符串
    # （用户完全可能把 SPEED_TEST_URL 配成和默认第一个一模一样，那是他的权利）。
    local _urls _u _res="" _rc=1
    if _conf_set SPEED_TEST_URL; then
        _urls="$SPEED_TEST_URL"
    else
        _urls="${SPEED_TEST_URLS:-$SPEED_TEST_URL}"
    fi
    for _u in $_urls; do
        _res="$(measure_throughput_once "$dev" "$tmo" "$_u")" && { _rc=0; break; }
    done
    [ "$_rc" = "0" ] || return 1
    printf '%s' "$_res"
    return 0
}

# 单源多连接测速。measure_throughput 按列表调它。
measure_throughput_once() {
    local dev="$1" tmo="$2" SPEED_TEST_URL="$3" out
    [ -n "$dev" ] || return 1
    dev_active "$dev" || return 1
    command -v curl >/dev/null 2>&1 || return 1

    # ── 为什么必须多连接测速 ──
    #
    # 原来这里是单条 curl。实测（同机同源，交替 3 轮）：
    #
    #     接口   1 连接    4 连接    8 连接
    #     en0    78.9      91.0      92.1 Mbps   ← 到顶，100baseTX 链路封死
    #     en1    82.3     218.6     270.6 Mbps   ← Wi-Fi 5GHz/160MHz
    #
    # 单连接下两者只差 4%（78.9 vs 82.3），测速会判"两条线差不多"，
    # 于是按延迟挑，很容易挑中有线——而**有线的真实容量只有 Wi-Fi 的 1/3**。
    # 用户看到的现象就是"智能选路选了更慢的那条"。
    #
    # 单连接测的是 TCP 单流速度，受慢启动、接收窗口、对端限流影响，
    # **不反映链路容量**。要多条并发才能把链路压到上限。
    #
    # 取 4 条：足以让两条线都接近各自的天花板（en0 91/92，en1 218/270），
    # 又不至于像 8 条那样把测速拖长、或触发对端限流。
    # 用 --interface 强制从这个网卡出去，否则测到的是默认路由那条。
    local T n_ok=0 sum=0 f
    T="$(mktemp -d /tmp/smartroute_speed.XXXXXX)" || {
        # 建不了临时目录就退回单连接，别让测速整个失败
        out="$(curl --interface "$dev" -o /dev/null -s -w '%{speed_download}' \
               --max-time "$tmo" "$SPEED_TEST_URL" 2>/dev/null)"
        case "$out" in ''|*[!0-9.]*) return 1 ;; esac
        awk -v v="$out" 'BEGIN{ exit !(v+0 > 0) }' || return 1
        printf '%s' "$out"
        return 0
    }
    local _i
    for _i in 1 2 3 4; do
        (
            curl --interface "$dev" -o /dev/null -s -w '%{speed_download}' \
                 --max-time "$tmo" "$SPEED_TEST_URL" > "$T/$_i" 2>/dev/null
        ) &
    done
    wait
    for f in "$T"/*; do
        [ -f "$f" ] || continue
        out="$(cat "$f" 2>/dev/null)"
        case "$out" in ''|*[!0-9.]*) continue ;; esac
        # curl 连不上时输出 0，那不是"测出来是 0"而是没测到，不计入
        awk -v v="$out" 'BEGIN{ exit !(v+0 > 0) }' || continue
        sum="$(awk -v a="$sum" -v b="$out" 'BEGIN{ printf "%.0f", a + b }')"
        n_ok=$(( n_ok + 1 ))
    done
    rm -rf "$T"
    # 一条都没测到才算失败。有任意一条成功就按**成功条数的平均**算，
    # 不能按 4 条算总和——否则 4 条里挂 3 条会把结果低估 4 倍，
    # 而那是网络抖动不是真实容量。
    [ "$n_ok" -gt 0 ] || return 1
    awk -v s="$sum" -v n="$n_ok" 'BEGIN{ printf "%.0f", s / n }'
}

# 字节/秒 -> "12.3 Mbps"
# 某接口累计收发的字节数。用于下载前后对比，看流量实际走了哪条线。
# 列位：Name(1) Mtu(2) Network(3) Address(4) Ipkts(5) Ierrs(6) Ibytes(7)
#       Opkts(8) Oerrs(9) Obytes(10) Coll(11)
_if_bytes() {   # $1=BSD 设备名 -> stdout: Ibytes+Obytes
    netstat -i -b -I "$1" 2>/dev/null | awk 'NR==2{print $7 + $10; exit}'
}

fmt_bytes() {   # $1=字节数 -> "1.5 GB" / "320.0 MB"
    awk -v b="${1:-0}" 'BEGIN{
        if (b <= 0) { print "0 B"; exit }
        # 用 1024 进制：下载工具和访达都按这个显示，混用会让用户对不上数
        if (b >= 1073741824) printf "%.2f GB", b / 1073741824
        else if (b >= 1048576) printf "%.1f MB", b / 1048576
        else if (b >= 1024) printf "%.1f KB", b / 1024
        else printf "%d B", b
    }'
}

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

# 从链路串（"100baseTX <full-duplex...>"）解析协商速率，单位 Mb/s。
# 解析不出输出空——调用方必须能区分"0"和"不知道"。
link_speed_mbps() {   # $1=link_media 输出
    case "$1" in
        2500base*|2.5gbase*|2.5Gbase*) echo 2500 ;;
        1000base*|1000Base*)           echo 1000 ;;
        100base*)                      echo 100 ;;
        10base*)                       echo 10 ;;
        *)                             echo "" ;;
    esac
}

# 网卡标称最大链路速率（Mb/s）。
#
# 为什么要读它：用户看到"有线 100M、Wi-Fi 432M"就问为什么不能相加成 532M。
# 真相往往是链路只协商到 100baseTX，而网卡其实是 2.5GbE——差的不是软件，
# 是网线或路由器端口。修好它一条线就能跑满千兆宽带，比任何软件聚合都强。
# 不说出来，用户会一直跟软件较劲。
nic_max_speed() {   # $1=BSD 设备名 -> stdout: Mb/s；读不到输出空
    [ -n "$1" ] || return 0
    system_profiler SPEthernetDataType 2>/dev/null | awk -v want="$1" '
        /BSD Device Name:/   { dev=$4; next }
        /Maximum Link Speed:/ && dev == want {
            v = $4; u = $5
            if (v + 0 <= 0) exit
            if (u ~ /^Gb/) printf "%d\n", v * 1000
            else if (u ~ /^Mb/) printf "%d\n", v
            exit
        }
    '
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
ensure_throughput() {   # $1=eth_dev $2=wifi_dev [$3=force 非空则忽略缓存新鲜度]
    local d force="${3:-}"
    for d in "$1" "$2"; do
        [ -n "$d" ] || continue
        # 注意不能写成 "[ -n "$force" ] || _metric_fresh ... && continue"：
        # bash 里 a || b && c 是左结合，等价于 (a || b) && c——force 非空时
        # 前半为真、照样 continue，正好把意思弄反。必须用 if 把分支写清楚。
        if [ -z "$force" ]; then
            _metric_fresh "speed_$d" "$SPEED_RECHECK" && continue
        fi
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
    # 非 root 时根本没法分别测两个接口：measure_latency 的探测路由只在 root 下加，
    # 于是两次调用测的都是**默认路由**，得到同一个数。
    #
    # 原来会把这两个相同的数分别存成 lat_en0 / lat_en1，状态页接着显示
    # "以太网 24.5ms / Wi-Fi 24.5ms"——看上去两条线都认真测过，实际只测了
    # 默认路由那一条。选路判断倒是安全的（两边相等 → pick_fastest 判 tie →
    # 保持现状），但展示是假的。
    #
    # 所以非 root 直接不写缓存，让上层看到"没有数据"，而不是看到一份
    # 以假乱真的对称数据。守护进程由 launchd 以 root 跑，正常不受影响；
    # 手动 bash smartroute watch 跑时才会走到这里。
    if [ "$(id -u)" -ne 0 ]; then
        return 0
    fi
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
    # 上界同样要查。实测查到的实例：state 文件里被写进
    #   speed_en0=99999999999999999999999
    # 时，status 原样打出
    #   实测吞吐 : eth=799999999999999872 Mbps
    # ——一个物理上不可能的吞吐，界面就那么显示着，像真测出来的一样。
    # 更糟的是这个值会流进 pick_by_speed 做大小比较，于是守护进程会
    # 认真地去切到一条"更快"的线上。**荒谬的数字比没有数字危险**：
    # 没有数字时界面说"未知"，用户知道要去测；荒谬的数字会被当成事实。
    #
    # 1e12 字节/秒 = 8 Tbps，比现存最快的网卡（100Gbps）还高两个数量级，
    # 真实测量永远碰不到这条线，只有损坏/手改/写入被截断才会越过。
    awk -v x="$v" 'BEGIN{ exit (x+0 < 1000000000000) ? 0 : 1 }' || return 0
    printf '%s' "$v"
}

# 按吞吐挑赢家：大的赢，差距不到 SPEED_SWITCH_RATIO 判 tie（保持现状）
pick_by_speed() {   # $1=设备A $2=BpsA $3=设备B $4=BpsB -> stdout: 设备名 | tie | 空
    # ⚠️ "一边是 0/空" **不是**"另一边更快"，而是"这一边没测到"。
    #
    # 实测踩过的坑：speed_en0=0（探测失败、源不可用、刚装上前两轮）
    # 时，老逻辑走 if (a+0 <= 0) { print d2 }，直接断言"en1 更快"。
    # 于是 status 打出「实测较快的是 en1」，而真相只是 en0 没测到——
    # 用户会以为有线就是慢，去换网线/换口，白忙一场。
    # cmd_watch 的 auto 分支同理：会把线路切到"没测到的那边之外"的另一边，
    # 而依据根本不存在。
    #
    # 所以：任一边缺数据就整体弃权（返回空），由调用方按可用性兜底。
    # 只有两边都有正数时才真的比大小。
    awk -v d1="$1" -v a="$2" -v d2="$3" -v b="$4" -v r="$SPEED_SWITCH_RATIO" 'BEGIN{
        if (a+0 <= 0 || b+0 <= 0) { exit }              # 任一边没测到 → 弃权
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
        fetch|dl)       cmd_fetch "$@" ;;
        boost)          cmd_boost "$@" ;;
        -h|--help|help) usage ;;
        *)              usage ;;
    esac
}

main "$@"

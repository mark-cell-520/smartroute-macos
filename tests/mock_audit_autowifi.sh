#!/bin/bash
# 复现：cmd_watch 的 AUTO_WIFI_POWER 分支永远不可能触发
#
# 位置：smartroute.sh:1396-1404
#
#     if [ "$AUTO_WIFI_POWER" = "1" ] && [ -n "$ACTIVE_WIFI_DEV" ] \
#        && [ "$wifi_res" = "na" ] && [ "$eth_ok" -ne 1 ] \
#        && [ "$(wifi_power "$ACTIVE_WIFI_DEV")" = "off" ]; then
#         ... set_wifi_power "$ACTIVE_WIFI_DEV" on
#
# 两个前提互相排斥：
#   · ACTIVE_WIFI_DEV 非空  ⟸ find_active 只收 dev_active 的设备，
#     而 dev_active = ifconfig 里有 inet 行（smartroute.sh:427-428）
#   · wifi_res = "na"      ⟸ probe_dev 判定"接口未激活/无 IP"（759-760 行），
#     即 dev_active 为假
#
# 而"Wi-Fi 被关闭"在 macOS 上正是"en1 没有 IPv4 地址"——所以真实场景
# （网线没网 + Wi-Fi 电源关闭）里 ACTIVE_WIFI_DEV 必然是空的，第一个条件就
# 把整条分支挡死。用户打开 AUTO_WIFI_POWER=1 后永远等不到那一条
# "已自动打开 Wi-Fi"日志，以太网断了就是真断网。
#
# 本测试用 mock 还原"网线没外网 + Wi-Fi 电源关闭"这一真实状态组合。
#
# 运行: bash tests/mock_audit_autowifi.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

SRC="$(pwd)/smartroute.sh"
T="$(mktemp -d /tmp/sr_awp.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/log" "$T/run" "$T/etc"
export MOCK_CALLS="$T/calls"; : > "$MOCK_CALLS"

# ── networksetup：Wi-Fi 硬件端口在，但电源是 Off ──
cat > "$T/bin/networksetup" <<'EOF'
#!/bin/bash
echo "networksetup $*" >> "$MOCK_CALLS"
case "$1" in
  -listallhardwareports)
      printf 'Hardware Port: Ethernet\nDevice: en0\n\nHardware Port: Wi-Fi\nDevice: en1\n' ;;
  -listnetworkserviceorder)
      printf '(1) Ethernet\n(Hardware Port: Ethernet, Device: en0)\n\n(2) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en1)\n' ;;
  -getinfo)   printf 'IP address: 192.168.1.5\nSubnet mask: 255.255.255.0\nRouter: 192.168.1.1\n' ;;
  -getairportpower) echo "Wi-Fi Power (en1): Off" ;;
  -setairportpower) echo "SET_AIRPORT_POWER $*" >> "$MOCK_CALLS" ;;
esac
exit 0
EOF
# ifconfig：en0 有 IP（网线插着），en1 没有任何 inet（Wi-Fi 电源关闭时的真实状态）
cat > "$T/bin/ifconfig" <<'EOF'
#!/bin/bash
case "$1" in
  en0) printf 'en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tinet 192.168.1.5 netmask 0xffffff00 broadcast 192.168.1.255\n' ;;
  en1) printf 'en1: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500\n\tether a0:1:2:3:4:5\n' ;;
esac
exit 0
EOF
# route：默认路由在 en0
cat > "$T/bin/route" <<'EOF'
#!/bin/bash
echo "route $*" >> "$MOCK_CALLS"
case "$*" in
  *"get default"*) printf '   route to: default\n destination: default\n  interface: en0\n' ;;
esac
exit 0
EOF
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo 0
exit 0
EOF
# 网线没有外网：ping/nc/curl 全失败
for c in ping nc curl; do
cat > "$T/bin/$c" <<'EOF'
#!/bin/bash
exit 1
EOF
done
cat > "$T/bin/pfctl" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$T/bin/date" <<'EOF'
#!/bin/bash
[ "${1:-}" = "+%s" ] && { echo "${MOCK_NOW:-1700000000}"; exit 0; }
exec /bin/date "$@"
EOF
chmod +x "$T/bin/"*

sed -e "s|^CONF=.*|CONF=\"$T/etc/smartroute.conf\"|" \
    -e "s|^USER_CONF=.*|USER_CONF=\"$T/etc/user.conf\"|" \
    -e "s|^RULES_FILE=.*|RULES_FILE=\"$T/etc/smartroute.rules\"|" \
    -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log/smartroute.log\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/lock\"|" \
    -e "s|^SVC_ORDER_BAK=.*|SVC_ORDER_BAK=\"$T/state/svc\"|" \
    -e "s|^PF_ANCHOR_FILE=.*|PF_ANCHOR_FILE=\"$T/etc/anchor\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"

run_watch() {   # $1=额外的子 shell 代码（用于对照组强制状态）
    : > "$T/calls"; : > "$T/state/state"; : > "$T/log/smartroute.log"
    bash -c "
        export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        export MOCK_CALLS='$MOCK_CALLS' MOCK_NOW=1700000000
        . '$T/sr.sh'
        trap - EXIT INT TERM HUP
        export AUTO_WIFI_POWER=1 NOTIFY=0 BALANCE=0 WIFI_FAILOVER=0
        ${1:-}
        cmd_watch
    " 2>&1
}

echo "== 1. 真实场景：网线没有外网 + Wi-Fi 电源关闭 =="
out="$(run_watch)"
printf '%s\n' "$out" | sed 's/^/    | /'
echo "    --- 日志 ---"; sed 's/^/    | /' "$T/log/smartroute.log" 2>/dev/null
echo "    --- 关键事实 ---"
printf '    ACTIVE_WIFI_DEV 是否为空: '
bash -c "
    export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
    . '$T/sr.sh'; trap - EXIT INT TERM HUP
    find_active; echo \"[\${ACTIVE_WIFI_DEV:-}]  (en1 有 inet 吗: \$(ifconfig en1 | grep -c 'inet '))\"
" 2>/dev/null | sed 's/^/    /'
grep -q "setairportpower en1 on" "$MOCK_CALLS" \
    && ok "调用了 setairportpower en1 on" \
    || bad "没有打开 Wi-Fi：AUTO_WIFI_POWER=1 形同虚设（网线断了也不会救）"
grep -q "自动打开 Wi-Fi" "$T/log/smartroute.log" \
    && ok "日志有说明" || bad "日志里没有任何相关记录（用户无从得知开关没生效）"

echo
echo "== 2. 对照：强行让 ACTIVE_WIFI_DEV 非空且 wifi_res=na（模拟毫秒级竞态）=="
out2="$(run_watch '
    find_active() { ACTIVE_ETH_DEV=en0; ACTIVE_ETH_SVC="Ethernet"
                    ACTIVE_WIFI_DEV=en1; ACTIVE_WIFI_SVC="Wi-Fi"; }
    probe_dev() { case "$1" in en0) echo fail ;; en1) echo na ;; esac; }')"
printf '%s\n' "$out2" | sed 's/^/    | /'
echo "    --- state ---"; sed 's/^/      /' "$T/state/state" 2>/dev/null
echo "    --- log ---";  sed 's/^/      /' "$T/log/smartroute.log" 2>/dev/null
echo "    --- calls ---"; sed 's/^/      /' "$T/calls" 2>/dev/null
echo "    --- 四个前提的实测值 ---"
bash -c "
    export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
    export MOCK_CALLS='$MOCK_CALLS'
    . '$T/sr.sh'
    trap - EXIT INT TERM HUP
    find_active() { ACTIVE_ETH_DEV=en0; ACTIVE_ETH_SVC='Ethernet'
                    ACTIVE_WIFI_DEV=en1; ACTIVE_WIFI_SVC='Wi-Fi'; }
    probe_dev() { case \"\$1\" in en0) echo fail ;; en1) echo na ;; esac; }
    echo \"      ACTIVE_WIFI_DEV=[\$ACTIVE_WIFI_DEV]  wifi_res=[\$(probe_dev en1 | sed -n 1p)]  wifi_power=[\$(wifi_power en1)]\"
" 2>/dev/null | sed 's/^/    /'
grep -q "setairportpower en1 on" "$MOCK_CALLS" \
    && ok "前提一旦同时满足，分支体本身能跑通（证明堵在入口条件，不是分支写错）" \
    || bad "分支体也跑不通——复现不成立"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

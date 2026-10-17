#!/bin/bash
# 链路能力差距：网线只谈到 100M，而网卡其实是 2.5GbE
#
# 为什么必须测：用户看到「有线 100M、Wi-Fi 432M」就问为什么不能相加成 532M。
# 真相是链路只协商到 100baseTX，网卡却能跑 2.5G——差的不是软件，是网线或
# 路由器端口。修好它一条有线就能跑满千兆宽带，比任何软件聚合都强。
# 这个差距不摆到用户眼前，他会一直跟软件较劲，还反复重装。
#
# 运行: bash tests/mock_linkspeed.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_ls.XXXXXX)"
mkdir -p "$T/bin" "$T/state" "$T/lock"
trap 'rm -rf "$T"' EXIT
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"
# system_profiler 太慢（0.4s/次）且输出随机器而变，测试里给假数据
cat > "$T/bin/system_profiler" <<'EOF'
#!/bin/bash
cat <<'PROF'
Ethernet:
    Realtek 8125 (2.5 GbE):
      BSD Device Name: en0
      Maximum Link Speed: 2.5 Gb/s
    Some USB Adapter:
      BSD Device Name: en4
      Maximum Link Speed: 1 Gb/s
PROF
EOF
chmod +x "$T/bin/system_profiler"
# cmd_status 要先 find_active 找到接口，否则 ACTIVE_ETH_DEV 为空、
# 整个以太网段被跳过——告警代码根本没机会跑（最早就是漏了这些，四项全红）。
# service_devices 从 "(Hardware Port: X, Device: enN)" 行拿服务名，
# hardware_ports 从 "Hardware Port: X / Device: enN" 两行拿端口。
cat > "$T/order" <<'EOF'
(1) Ethernet
(Hardware Port: Ethernet, Device: en0)

(2) Wi-Fi
(Hardware Port: Wi-Fi, Device: en1)
EOF
cat > "$T/hw" <<'EOF'
Hardware Port: Wi-Fi
Device: en1

Hardware Port: Ethernet
Device: en0
EOF
cat > "$T/info" <<'EOF'
Wi-Fi|192.168.1.1|192.168.1.5
Ethernet|192.168.1.1|192.168.1.36
EOF
printf '   route to: default\n  interface: en0\n  gateway: 192.168.1.1\n' > "$T/def_en0"
cat > "$T/bin/networksetup" <<'EOF'
#!/bin/bash
case "${1:-}" in
    -getMedia)
        echo "Current: autoselect"
        echo "Active: ${MOCK_MEDIA:-1000baseT} <full-duplex>" ;;
    -listnetworkserviceorder) cat "$MOCK_ORDER" ;;
    -listallhardwareports)    cat "$MOCK_HW" ;;
    -getinfo) awk -F'|' -v s="$2" '$1==s{print "Router: "$2}' "$MOCK_INFO" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$T/bin/networksetup"
cat > "$T/bin/ifconfig" <<'EOF'
#!/bin/bash
case "$1" in en0|en1) echo "$1: flags=8863<UP> mtu 1500"; echo -e "\tinet 192.168.1.5 netmask 0xffffff00"; exit 0 ;; esac
exec /sbin/ifconfig "$@"
EOF
chmod +x "$T/bin/ifconfig"
cat > "$T/bin/route" <<'EOF'
#!/bin/bash
case "${1:-}" in -n) [ -f "$MOCK_DEFAULT" ] && cat "$MOCK_DEFAULT"; exit 0 ;; esac
exit 0
EOF
chmod +x "$T/bin/route"
chmod +x "$T/bin/networksetup"
ev() { bash -c ". '$T/sr.sh'; trap - EXIT INT TERM HUP
        export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        export MOCK_ORDER='$T/order' MOCK_HW='$T/hw' MOCK_INFO='$T/info' MOCK_DEFAULT='$T/def_en0'
        export STATE_FILE='$T/state/st' LOCK_DIR='$T/lock'
        $1" 2>/dev/null; }

echo "== 1. link_speed_mbps 解析各种链路串 =="
[ "$(ev 'link_speed_mbps 1000baseT')" = "1000" ] && ok "1000baseT -> 1000" || bad "1000baseT 解析错: $(ev 'link_speed_mbps 1000baseT')"
[ "$(ev 'link_speed_mbps "100baseTX <full-duplex flow-control>"')" = "100" ] && ok "100baseTX(带描述) -> 100" || bad "100baseTX 解析错"
[ "$(ev 'link_speed_mbps 10baseT/UTP')" = "10" ] && ok "10baseT/UTP -> 10" || bad "10baseT 解析错"
[ "$(ev 'link_speed_mbps 2500baseT')" = "2500" ] && ok "2500baseT -> 2500" || bad "2500baseT 解析错"
[ -z "$(ev 'link_speed_mbps autoselect')" ] && ok "认不出的输出空（不是 0）" || bad "未知串应输出空"
# 顺序陷阱：1000baseT 也含 "100"，先匹配 100base* 会错
[ "$(ev 'link_speed_mbps 1000baseT')" = "1000" ] && ok "1000baseT 没被误判成 100（模式顺序正确）" || bad "1000baseT 被误判"

echo "== 2. nic_max_speed 按设备名取，单位换算 =="
[ "$(ev 'nic_max_speed en0')" = "2500" ] && ok "2.5 Gb/s -> 2500" || bad "2.5G 换算错: $(ev 'nic_max_speed en0')"
[ "$(ev 'nic_max_speed en4')" = "1000" ] && ok "1 Gb/s -> 1000" || bad "1G 换算错: $(ev 'nic_max_speed en4')"
[ -z "$(ev 'nic_max_speed en9')" ] && ok "不存在的设备输出空" || bad "不存在的设备应有空输出"

echo "== 3. 差距必须触发告警（本机实况 100 vs 2500）=="
_out="$(MOCK_MEDIA=100baseTX ev 'cmd_status' 2>/dev/null)"
echo "$_out" | grep -q "只协商到 100M，而网卡支持 2500M" \
    && ok "100M vs 2500M 时告警" || bad "本机实况没有告警: $(echo "$_out" | grep -i '协商\|链路' | head -3)"
echo "$_out" | grep -q "这不是本工具的限制" \
    && ok "明确说不是软件问题（否则用户跟工具较劲）" || bad "没说清责任归属"
echo "$_out" | grep -q "Cat5e" \
    && ok "给出可操作建议（换线）" || bad "没给换线建议"
echo "$_out" | grep -q "强于任何两条线的软件聚合" \
    && ok "说明修好一条线比软件聚合更强（回答为什么不相加）" || bad "没回答为什么不相加"

echo "== 4. 没差距时不告警（不制造假警报）=="
_out="$(MOCK_MEDIA=1000baseT ev 'cmd_status' 2>/dev/null)"
echo "$_out" | grep -q "只协商到" \
    && bad "1000M vs 2500M 仍告警（应为提示而非警告，或阈值太松）" \
    || ok "1000M 时不告警"
_out="$(MOCK_MEDIA=2500baseT ev 'cmd_status' 2>/dev/null)"
echo "$_out" | grep -q "只协商到" \
    && bad "跑满 2500M 还告警" || ok "跑满网卡能力时不告警"

echo ""
echo "结果: $((PASS - FAIL)) 通过, $FAIL 失败"

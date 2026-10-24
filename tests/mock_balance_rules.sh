#!/bin/bash
# mock 测试：apply_rules / write_pf_rules / cmd_rule
# 用假的 route/netstat/pfctl/ifconfig/networksetup 验证逻辑，不动真实系统
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)/smartroute.sh"
T=/tmp/sr_mock2
rm -rf "$T"; mkdir -p "$T/bin" "$T/state" "$T/etc" "$T/log"
PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# ---- 构造 mock 命令 ----
cat > "$T/bin/route" <<'EOF'
#!/bin/bash
echo "route $*" >> "$MOCK_LOG"
exit 0
EOF
cat > "$T/bin/pfctl" <<'EOF'
#!/bin/bash
echo "pfctl $*" >> "$MOCK_LOG"
# -s info 返回 pf 状态；-s rules 返回规则；-s nat 返回 NAT 计数
case "$*" in
  *"-s info"*) echo "Status: ${MOCK_PF_STATUS:-Disabled}" ;;
  *"-s rules"*) [ "${MOCK_ANCHOR_LOADED:-0}" = "1" ] && echo "pass out route-to { (en0 192.168.1.1) (en1 192.168.1.1) } round-robin" ;;
  *"-s nat"*)
      if [ "${MOCK_NAT:-0}" = "1" ]; then
        echo "nat-to 192.168.2.36 -> 192.168.2.36"
        echo "  [ Evaluations: 20  Packets: 12  Bytes: 1200 ]"
        echo "nat-to 192.168.1.5 -> 192.168.1.5"
        echo "  [ Evaluations: 20  Packets: 10  Bytes: 1000 ]"
      fi ;;
esac
exit 0
EOF
cat > "$T/bin/networksetup" <<'EOF'
#!/bin/bash
# 只拦 -getinfo（svc_router 只认 "Router: <ip>" 这一行）。
# 其余子命令放行给真实命令——find_active 要用 -listnetworkserviceorder，
# 全拦了会让它取不到接口，前面一大堆测试跟着挂。
if [ "${1:-}" = "-getinfo" ]; then
  case "$2" in
    # "none" 是哨兵：表示"这个接口取不到网关"。
    # 不能直接传空串——run() 那边有 :-默认值，空串会被填回默认网关。
    Ethernet) echo "IP address: 192.168.1.36"; [ "${MOCK_ETH_GW:-}" = none ] || echo "Router: ${MOCK_ETH_GW:-192.168.1.1}" ;;
    Wi-Fi)    echo "IP address: 192.168.1.5";  [ "${MOCK_WIFI_GW:-}" = none ] || echo "Router: ${MOCK_WIFI_GW:-192.168.1.1}" ;;
  esac
  exit 0
fi
exec /usr/sbin/networksetup "$@"
EOF
cat > "$T/bin/netstat" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-rn" ]; then
  cat "$MOCK_ROUTES" 2>/dev/null
elif [ "${1:-}" = "-I" ]; then
  # 计数器每次 +70000 模拟流量增长；MOCK_FROZEN 指定的接口不增长。
  # 为什么是 70000 而不是 1000：balance_validate 用两次采样的差值判断
  # "某侧是否真的在扛"。以前这里 +1000，于是测试固化了一个错误假设——
  # "两边都有流量就算分流生效"。而真实情况是 10 个连通性探测
  # （ping 64B + nc + curl TLS）产生的出站流量就在几十 KB 以上，
  # 而 Wi-Fi 纯背景心跳（mDNS/ARP/DHCP/iCloud）只有几百字节。
  # 1000 这个量级正好落在"背景心跳"区间，用来验证分流是错的。
  f="$MOCK_BYTES_DIR/$2"
  b=$(cat "$f" 2>/dev/null || echo 0)
  if [ "${MOCK_FROZEN:-}" != "$2" ]; then b=$((b + 70000)); echo "$b" > "$f"; fi
  printf 'Name  Mtu  Network  Address  Ipkts Ierrs  Ibytes  Opkts Oerrs  Obytes  Coll\n'
  printf '%-6s 1500  <Link>  aa:bb   100  0  %s  50  0  %s  0\n' "$2" "$((b*2))" "$b"
fi
exit 0
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$MOCK_LOG"
[ "${MOCK_NET_OK:-1}" = "1" ] && exit 0 || exit 7
EOF
cat > "$T/bin/nc" <<'EOF'
#!/bin/bash
echo "nc $*" >> "$MOCK_LOG"
[ "${MOCK_NET_OK:-1}" = "1" ] && exit 0 || exit 1
EOF
cat > "$T/bin/ping" <<'EOF'
#!/bin/bash
echo "ping $*" >> "$MOCK_LOG"
# 按目标 IP 最后一段决定返回的 RTT，用来模拟"某条线路更快"
# MOCK_RTT_en0 / MOCK_RTT_en1 可覆盖默认值
t="${!#}"
case "$t" in
  *.1) r="${MOCK_RTT_A:-14.0}" ;;
  *)   r="${MOCK_RTT_B:-14.0}" ;;
esac
if [ "${MOCK_PING_OK:-1}" != "1" ]; then echo "ping: sendto: No route to host" >&2; exit 1; fi
echo "PING $t: 56 data bytes"
echo "64 bytes from $t: icmp_seq=0 ttl=53 time=$r ms"
echo "64 bytes from $t: icmp_seq=1 ttl=53 time=$r ms"
echo ""
echo "--- $t ping statistics ---"
echo "2 packets transmitted, 2 packets received, 0.0% packet loss"
echo "round-trip min/avg/max/std-dev = $r/$r/$r/0.1 ms"
exit 0
EOF
cat > "$T/bin/ifconfig" <<'EOF'
#!/bin/bash
d="$1"
case "$d" in
  en1) echo "        inet 192.168.1.5 netmask 0xffffff00 broadcast 192.168.1.255" ;;
  en6) echo "        inet 192.168.1.6 netmask 0xffffff00 broadcast 192.168.1.255" ;;
  en0) echo "        inet 192.168.2.36 netmask 0xffffff00 broadcast 192.168.2.255" ;;
  en5) echo "        inet 192.168.3.7 netmask 0xffffff00 broadcast 192.168.3.255" ;;
  *) exit 1 ;;
esac
exit 0
EOF
mkdir -p "$T/bytes"
chmod +x "$T/bin/"*

# 被测脚本：改路径到 /tmp，并剥掉入口段（只保留函数定义）
sed -e "s|^CONF=.*|CONF=\"$T/etc/smartroute.conf\"|" \
    -e "s|^USER_CONF=.*|USER_CONF=\"$T/etc/user.conf\"|" \
    -e "s|^RULES_FILE=.*|RULES_FILE=\"$T/etc/smartroute.rules\"|" \
    -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log/smartroute.log\"|" \
    -e "s|^PF_ANCHOR_FILE=.*|PF_ANCHOR_FILE=\"$T/etc/pf.anchor\"|" \
    -e "s|^PF_STATE_FILE=.*|PF_STATE_FILE=\"$T/state/pf.state\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"
chmod +x "$T/sr.sh"

export PATH="$T/bin:$PATH"
export MOCK_LOG="$T/calls.log"
export MOCK_ROUTES="$T/routes.txt"
: > "$MOCK_LOG"
cat > "$MOCK_ROUTES" <<'EOF'
Destination        Gateway            Flags    Refs    Use    Netif
default            192.168.1.1        UGScg     12      0      en1
127/8              127.0.0.1          UCS        1      0      lo0
192.168.1/24       link#16            UCS        2      0      en1
EOF
export MOCK_PF_STATUS=Disabled MOCK_ANCHOR_LOADED=0 MOCK_NAT=0 MOCK_D1=en0 MOCK_D2=en1
# 假装是 root，让 apply_rules 走完整逻辑
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo 0
exit 0
EOF
chmod +x "$T/bin/id"

run() {   # 在隔离环境里 source 并执行函数
    local pp="$T/bin:$PATH"
    bash -c "
        export PATH='$pp'
        export MOCK_LOG='$MOCK_LOG' MOCK_ROUTES='$MOCK_ROUTES'
        export MOCK_BYTES_DIR='$T/bytes'
        export MOCK_PF_STATUS='${MOCK_PF_STATUS:-Disabled}' MOCK_ANCHOR_LOADED='${MOCK_ANCHOR_LOADED:-0}'
        export MOCK_NAT='${MOCK_NAT:-0}' MOCK_CURL_OK='${MOCK_CURL_OK:-1}'
        export MOCK_ETH_GW='${MOCK_ETH_GW:-192.168.1.1}' MOCK_WIFI_GW='${MOCK_WIFI_GW:-192.168.1.1}'
        . '$T/sr.sh'
        $1
    "
}

echo "== 1. cmd_rule add/list/del =="
run "cmd_rule add 10.0.0.0/8 en0" | grep -q "已添加规则: 10.0.0.0/8 -> en0" && ok "add 写入规则" || bad "add 写入规则"
run "cmd_rule add 192.168.2.0/24 en4" | grep -q "已添加规则" && ok "add 第二条规则" || bad "add 第二条规则"
run "cmd_rule add 10.0.0.0/8 en0" | grep -q "已添加" && ok "重复 add 不重复（去重）" || bad "重复 add 去重"
[ "$(run "cmd_rule list" | grep -c "^  10.0.0.0/8")" = "1" ] && ok "重复规则只出现一次" || bad "重复规则去重后列表"
run "cmd_rule add bad en0" >/dev/null 2>&1 && bad "非法 CIDR 被拒绝" || ok "非法 CIDR 被拒绝"
run "cmd_rule add 10.0.0.0/8 enXX" >/dev/null 2>&1 && bad "不存在接口被拒绝" || ok "不存在接口被拒绝"
run "cmd_rule list" | grep -q "192.168.2.0/24" && ok "list 显示规则" || bad "list 显示规则"

echo "== 2. apply_rules（root 逻辑）=="
run "cmd_rule add 10.0.0.0/8 en0" >/dev/null
: > "$MOCK_LOG"
run "apply_rules" >/dev/null
grep -q "route add -net 10.0.0.0/8 192.168.1.1" "$MOCK_LOG" && ok "按规则添加静态路由" || { bad "按规则添加静态路由"; cat "$MOCK_LOG"; }
# 已有路由则不再添加（MOCK_ROUTES 里加一条）
grep -q "10/8" "$MOCK_ROUTES" || printf '10/8              192.168.1.1        UGScg       1      0      en0\n' >> "$MOCK_ROUTES"
: > "$MOCK_LOG"
run "apply_rules" >/dev/null
grep -q "route add -net 10.0.0.0/8" "$MOCK_LOG" && bad "已存在的路由不重复添加" || ok "已存在的路由不重复添加"
# 删除规则后应删除路由
run "cmd_rule del 10.0.0.0/8" >/dev/null
: > "$MOCK_LOG"
run "apply_rules" >/dev/null
grep -q "route delete -net 10.0.0.0/8" "$MOCK_LOG" && ok "规则删除后移除静态路由" || { bad "规则删除后移除静态路由"; cat "$MOCK_LOG"; }

echo "== 3. write_pf_rules =="
: > "$MOCK_LOG"
run "write_pf_rules en1 192.168.1.1 en6 192.168.1.1 ''" >/dev/null
grep -q "round-robin" "$T/etc/pf.anchor" && ok "生成轮询规则" || bad "生成轮询规则"
# 这一条以前断言的是"同网段不写 NAT"，理由写的是"源地址天然合法"。
# 那个理由是错的，而且错得正好把唯一的提速路径堵死，所以反过来断言：
#   内核按路由表选源地址。同网段时去网关的路由只指向默认路由那个接口
#   （en0），源地址固定是 en0 的 IP。pf 的 route-to 只改出口、不改源地址。
#   于是包带着 en0 的 IP 从 Wi-Fi 出去，路由器按 ARP 知道这个 IP 在有线口，
#   回程全走有线。对下载这致命：下行永远 100M，Wi-Fi 那 432M 一点用不上。
#   用户看到的现象就是"开了并发下载还是 100M"。
# 加 nat on en1 -> (en1) 把源地址改写成 en1 的 IP，回程才真的走 Wi-Fi。
grep -q "nat on" "$T/etc/pf.anchor" && ok "同网段也必须写 NAT（否则回程涌向另一接口）" || bad "同网段没有 NAT，下载会被钉死在慢的那条线上"
grep -q "192.168.1.0/24" "$T/etc/pf.anchor" && ok "同网段只排除一个网段" || bad "同网段排除项"
run "write_pf_rules en1 192.168.1.1 en0 192.168.1.1 ''" >/dev/null
grep -q "nat on" "$T/etc/pf.anchor" && ok "不同网段写 NAT" || bad "不同网段写 NAT"
run "write_pf_rules en1 192.168.1.1 en5 192.168.2.1 100.64.0.0/16" >/dev/null
grep -q "100.64.0.0/16" "$T/etc/pf.anchor" && ok "VPN 网段被排除" || bad "VPN 网段被排除"
grep -q "已排除 VPN/拨号网段" "$T/etc/pf.anchor" && ok "规则文件记录排除项" || bad "规则文件记录排除项"
grep -q "nat-to" "$T/etc/pf.anchor" && ok "不同网段生成 NAT 规则" || bad "不同网段生成 NAT 规则"
grep -q 'route-to { ($ext1 $gw1) ($ext2 $gw2) }' "$T/etc/pf.anchor" && ok "route-to 语法正确" || { bad "route-to 语法"; cat "$T/etc/pf.anchor"; }
grep -q "192.168.3.0/24" "$T/etc/pf.anchor" && ok "两个网段都排除" || bad "两个网段都排除"

echo "== 4. balance_validate =="
export MOCK_NET_OK=1 MOCK_FROZEN=""
: > "$MOCK_LOG"
run "balance_validate en0 192.168.2.36 en1 192.168.1.5" >/dev/null && ok "两接口都有流量时验证通过" || bad "两接口都有流量时应通过"

echo "== 4a. 背景心跳量级的流量 → 应判失败（修 P0-3）=="
# 以前只判"字节数 > 0"。Wi-Fi 只要关联着就永远有背景流量
# （mDNS/ARP/DHCP/iCloud 心跳，几百字节起步），于是 pf route-to
# 根本没生效时这一侧也"有流量"——验证通过、打出"✅ 已开启"，
# 用户拿着这份假证据去排查其他方向，比没有检查更糟。
cat > "$T/bin/netstat_small" <<'SMALL'
#!/bin/bash
f="$MOCK_BYTES_DIR/$2"
b=$(cat "$f" 2>/dev/null || echo 0)
if [ "${MOCK_FROZEN:-}" != "$2" ]; then b=$((b + 300)); echo "$b" > "$f"; fi
printf 'Name  Mtu  Network  Address  Ipkts Ierrs  Ibytes  Opkts Oerrs  Obytes  Coll\n'
printf '%-6s 1500  <Link>  aa:bb   100  0  %s  50  0  %s  0\n' "$2" "$((b*2))" "$b"
SMALL
chmod +x "$T/bin/netstat_small"
# bin_small 必须先建出来。以前漏了 mkdir -p，cp 到不存在的目录静默失败，
# 内层 PATH 里的 $T/bin_small/netstat 不存在 → 回退到**真实 netstat**，
# 读真实网卡计数器。同时 nc/curl 也是真的，真的发了 10 次外网连接。
# 于是这一节变成"碰运气"：真实流量恰好超过 64KB 时验证通过，
# 两条断言一起挂（实测约 8% 概率），流量低时又通过——典型的 flaky。
mkdir -p "$T/bin_small"; rm -f "$T/bin_small"/* 2>/dev/null
cp "$T/bin/netstat_small" "$T/bin_small/netstat"; chmod +x "$T/bin_small/netstat"
out="$(MOCK_BYTES_DIR="$T/bytes_small" PATH="$T/bin:$PATH" \
      bash -c "
        export PATH='$T/bin_small:$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        export LOCK_DIR='$T/lock' STATE_FILE='$T/state/st' PF_ANCHOR_FILE='$T/none'
        . '$T/sr.sh'; trap - EXIT INT TERM HUP
        export MOCK_BYTES_DIR='$T/bytes_small'
        balance_validate en0 192.168.2.36 en1 192.168.1.5" 2>&1)"
echo "$out" | grep -q "验证失败" \
    && ok "几百字节的背景心跳判为失败（不当成分流证据）" || bad "背景心跳被当成分流生效"
echo "$out" | grep -q "判定标准" \
    && ok "说明了判定标准（单侧 ≥64KB 且占比 ≥10%）" || bad "没说判定标准"

echo "== 4b. 单接口无流量 → 应失败 =="
export MOCK_FROZEN="en1"
: > "$MOCK_LOG"
out="$(run 'balance_validate en0 192.168.2.36 en1 192.168.1.5' 2>&1)"
echo "$out" | grep -q "流量没有走预期接口" && ok "单接口无流量时明确报错" || bad "单接口无流量未报错: $out"
export MOCK_FROZEN=""

echo "== 4c. 网络不通 → 应失败 =="
export MOCK_NET_OK=0
: > "$MOCK_LOG"
out="$(run 'balance_validate en0 192.168.2.36 en1 192.168.1.5' 2>&1)"
# 现在网络不通会走"前 4 次全灭即快速失败"分支，措辞和跑满 10 次时不同，
# 但两者都算明确报错 + 自动还原。断言要同时认这两种。
echo "$out" | grep -qE "TCP 测试连接只有|前 4 次探测全部超时" \
    && ok "网络不通时明确报错（含成功数或快速失败原因）" || bad "网络不通未报错: $out"
export MOCK_NET_OK=1

echo "== 5. balance_status 不炸 =="
run "balance_status" | grep -q "系统 pf" && ok "balance_status 可读" || bad "balance_status"

echo "== 6. balance_off 还原 =="
export MOCK_PF_STATUS=Enabled
printf 'pf_enabled_by_us=1\n' > "$T/state/pf.state"
: > "$MOCK_LOG"
run "balance_off quiet" >/dev/null
grep -q "pfctl -a com.apple/smartroute -F all" "$MOCK_LOG" && ok "撤销时清空 anchor" || bad "撤销时清空 anchor"
grep -q "pfctl -d" "$MOCK_LOG" && ok "我们开启的 pf 会被关闭" || bad "关闭我们开启的 pf"
[ -f "$T/state/pf.state" ] && bad "pf 状态文件已清理" || ok "pf 状态文件已清理"
grep -q "BALANCE=0" "$T/etc/user.conf" || grep -q "BALANCE=0" "$T/etc/smartroute.conf" \
    && ok "BALANCE 开关已置 0" || bad "BALANCE 开关置 0"

echo "== 7. 延迟测量与最快线路选速 =="
export MOCK_PING_OK=1 MOCK_RTT_A=14.0 MOCK_RTT_B=14.0
: > "$MOCK_LOG"
r="$(run 'measure_latency en1 192.168.1.1' 2>/dev/null | tail -n 1)"
case "$r" in
  14.0|14) ok "measure_latency 返回平均 RTT ($r ms)" ;;
  *) bad "measure_latency 返回值异常: [$r]" ;;
esac

# [v2.4] 新路径断言：measure_latency 必须用 ping -b 绑定接口。
# 背景：旧的主机路由法在同网关双接口机器上给 en1 加路由会加错口
# （内核选成默认口），出口验证全军覆没 → lat_en1 永远缺失 →
# auto 的延迟一票否决持续弃权。实测这台机器 Wi-Fi 网关 RTT 恶化到
# 1.1 秒都没能触发切换。ping -b 不需要 root、不受同网关歧义影响。
grep -q "ping -b en1" "$MOCK_LOG" \
    && ok "measure_latency 用 ping -b 绑定接口（不依赖 root 主机路由）" \
    || bad "measure_latency 还在用旧的主机路由法（同网关双接口下 lat 会缺失）"

export MOCK_RTT_A=10.0 MOCK_RTT_B=40.0
w="$(run 'pick_fastest en0 10.0 en1 40.0' 2>/dev/null | tail -n 1)"
[ "$w" = "en0" ] && ok "延迟差大时选出更快的 en0" || bad "选速失败: $w"
w="$(run 'pick_fastest en0 14.0 en1 12.0' 2>/dev/null | tail -n 1)"
[ "$w" = "tie" ] && ok "差距小于阈值时判为 tie（继续轮询）" || bad "tie 判定失败: $w"
w="$(run 'pick_fastest en0 "" en1 12.0' 2>/dev/null | tail -n 1)"
[ "$w" = "en1" ] && ok "一边测不到时选另一边" || bad "单边测量失败处理: $w"
w="$(run 'pick_fastest en0 "" en1 ""' 2>/dev/null | tail -n 1)"
[ -z "$w" ] && ok "两边都测不到时返回空（回退轮询）" || bad "双边失败处理: $w"

echo "== 8. fastest 模式生成的 pf 规则 =="
export MOCK_RTT_A=14.0 MOCK_RTT_B=14.0
: > "$MOCK_LOG"
run "write_pf_rules en1 192.168.1.1 en6 192.168.1.1 '' en1" >/dev/null
grep -q 'route-to { (\$ext1 \$gw1) }' "$T/etc/pf.anchor" && ok "fastest 只放一个网关进 route-to" || bad "fastest 规则未收敛成单网关"
grep -q "round-robin" "$T/etc/pf.anchor" && bad "fastest 不应出现 round-robin" || ok "fastest 不写 round-robin"
grep -q "策略: fastest" "$T/etc/pf.anchor" && ok "规则文件标注 fastest 策略" || bad "未标注策略"

echo "== 9. balance_validate 在 fastest 下只要求赢家有流量 =="
export MOCK_NET_OK=1 MOCK_FROZEN="en6"
: > "$MOCK_LOG"
run "balance_validate en1 192.168.1.5 en6 192.168.1.6 en1" >/dev/null && ok "赢家接口有流量即通过" || bad "fastest 验证误判"
export MOCK_FROZEN="en1"
: > "$MOCK_LOG"
out="$(run 'balance_validate en1 192.168.1.5 en6 192.168.1.6 en1' 2>&1)"
echo "$out" | grep -q "流量没有走预期接口" && ok "赢家没流量时明确报错" || bad "赢家无流量未报错: $out"
export MOCK_FROZEN=""

echo
echo "== 12. 同网关（一条 WAN 的两个入口）不该开双网并发 =="
# 这是实测发现的：本机网线和 Wi-Fi 的网关都是 192.168.1.1，
# 同一台路由器出来的。此时 pf 轮询分流不会变快——瓶颈在路由器
# 后面那一条上游，不在入口；反而一半连接被赶到更慢的接口。
# 默认拒绝，--force 才放行（给想验证 pf 规则的人留口子）。
_g() {   # 在隔离环境里判断同网关，$1/$2 为两个网关
    run "
        ACTIVE_ETH_DEV=en0; ACTIVE_ETH_SVC=Ethernet
        ACTIVE_WIFI_DEV=en1; ACTIVE_WIFI_SVC=Wi-Fi
        export MOCK_ETH_GW='$1' MOCK_WIFI_GW='$2'
        eth_wifi_same_gateway && echo SAME || echo DIFF
    "
}
[ "$(_g 192.168.1.1 192.168.1.1)" = "SAME" ] && ok "网关相同能被判出来" || bad "网关相同能被判出来"
[ "$(_g 192.168.1.1 10.0.0.1)" = "DIFF" ] && ok "网关不同不会被误判" || bad "网关不同不会被误判"
# 判断不了时不能当成"相同"，否则会误拒合法的双 WAN
[ "$(_g none none)" = "DIFF" ] && ok "取不到网关时不当成相同（不误拒）" || bad "取不到网关时当成相同了"
# 只一边取不到同样不能开（规则会不完整）
[ "$(_g none 10.0.0.1)" = "DIFF" ] && ok "只一边有网关时判 DIFF" || bad "只一边有网关时误判 SAME"
# 少一个接口也要判不了，而不是崩
run '
    ACTIVE_ETH_DEV=en0; ACTIVE_ETH_SVC=Ethernet; ACTIVE_WIFI_DEV=
    eth_wifi_same_gateway && echo SAME || echo DIFF
' | grep -q "^DIFF$" && ok "没有 Wi-Fi 时判 DIFF（不误拒）" || bad "没有 Wi-Fi 时误判"

_st() {   # balance_status 在给定网关下的输出
    # 2>/dev/null：grep -q 一命中就关掉管道，脚本里的 echo 会报
    # "Broken pipe"——那是测试管道的正常现象，不是错误，别让它污染输出。
    run "
        ACTIVE_ETH_DEV=en0; ACTIVE_ETH_SVC=Ethernet
        ACTIVE_WIFI_DEV=en1; ACTIVE_WIFI_SVC=Wi-Fi
        export MOCK_ETH_GW='$1' MOCK_WIFI_GW='$2'
        balance_status
    " 2>/dev/null
}
_st 192.168.1.1 192.168.1.1 | grep -q "两个接口网关相同（192.168.1.1）" \
    && ok "同网关时 status 警告并带上网关" || bad "同网关时 status 未警告"
_st 192.168.1.1 192.168.1.1 | grep -q "建议 BALANCE=0" \
    && ok "警告里给出关闭建议" || bad "警告里没有关闭建议"
_st 192.168.1.1 10.0.0.1 | grep -q "两个接口网关相同" \
    && bad "不同网关时乱警告（狼来了）" || ok "不同网关时不警告"

echo
echo "== 13. balance on --force：同网关时一律拒绝（逃生门已拆除）=="
# 原来同网关默认拒绝、--force 放行，注释写的是"给想验证 pf 规则的人留口子"。
# 但用户正是照着我们自己印的提示去 --force 的，然后网络卡死：
# 回包走错接口被 pf 状态表丢弃，网页打不开、一直转圈，
# 只能自己想到 balance off 才恢复。这个现象被报告过两次。
#
# 而同网关下 pf 分流收益实测为零（瓶颈在路由器后面的上游，不在入口）。
# 零收益 + 已证实的卡死风险 = 这个口子没有理由存在，所以拆掉。
#
# --force 仍然要从参数里摘掉：不摘的话它会落进用法检查的 *) 分支被当成
# mode，直接报"用法"错误（这个 bug 出过一次）。所以断言的是
# "带 --force 也走到同网关拒绝"，而不是"用法错误"。
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }   # 伪装成 root，否则过不了第一道检查
exec /usr/bin/id "$@"
EOF
chmod +x "$T/bin/id"
mkdir -p "$T/lock"
# 注意：不能直接用上面的 run()。脚本第 2 行会把 PATH 重置成
# /usr/local/sbin:...，把 $T/bin 冲掉，id/pfctl 这两个 mock 就失效了
# （表现为"双网并发需要 root"）。所以这里自己起 bash，
# 在 . sr.sh **之后**再设 PATH。
_bo2() {
    # 2>&1：被拒绝时 balance_on 的解释是写到 stderr 的（cat >&2），
    # 只收 stdout 会什么都看不到，测试会以为"没有输出"而误判。
    bash -c "
        . '$T/sr.sh'
        export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        LOCK_DIR='$T/lock'
        ACTIVE_ETH_DEV=en0; ACTIVE_ETH_SVC=Ethernet
        ACTIVE_WIFI_DEV=en1; ACTIVE_WIFI_SVC=Wi-Fi
        export MOCK_ETH_GW=192.168.1.1 MOCK_WIFI_GW=192.168.1.1
        balance_on $1
    " 2>&1 | grep -v 'Broken pipe'
}
_verdict() {   # 打印 balance_on 的判定：拒绝 / 放行 / 用法错误 / 其他
    local out
    out="$(_bo2 "$1")"
    case "$out" in
        *"会让网页卡壳"*)       echo "拒绝" ;;
        *"已按 --force 强开"*)   echo "放行" ;;
        *"用法"*)              echo "用法错误" ;;
        *)                     echo "其他: $(printf '%s' "$out" | head -1)" ;;
    esac
}
[ "$(_verdict '')" = "拒绝" ] && ok "不带 --force 被拒绝" || bad "不带 --force：$(_verdict '')"
# 下面三条是新行为的核心：同网关时 --force 一律不再放行。
# 但 --force 必须仍被从参数里摘掉，否则会落进用法检查报"用法错误"。
[ "$(_verdict '--force')" = "拒绝" ] && ok "--force 单独也拒绝（且没被当成 mode）" || bad "--force 单独：$(_verdict '--force')"
[ "$(_verdict 'fastest --force')" = "拒绝" ] && ok "模式在前 --force 在后也拒绝" || bad "fastest --force：$(_verdict 'fastest --force')"
[ "$(_verdict '--force fastest')" = "拒绝" ] && ok "--force 在前 模式在后也拒绝" || bad "--force fastest：$(_verdict '--force fastest')"
# 拒绝理由里必须给出替代方案，否则用户只知道不行、不知道该怎么办
_bo2 '' 2>&1 | grep -q "smartroute fetch" \
    && ok "拒绝时给出替代方案（fetch -n N）" || bad "拒绝时没说该怎么办"
[ "$(_verdict 'round-robin')" = "拒绝" ] && ok "合法模式仍被拒（同网关）" || bad "round-robin：$(_verdict 'round-robin')"
[ "$(_verdict 'bogus')" = "用法错误" ] && ok "非法模式仍报用法错误" || bad "bogus：$(_verdict 'bogus')"

echo
echo "== 14. 规则应用路径必须校验（/Users/Shared 是世界可写的） =="
# /Users/Shared 是 drwxrwxrwt，任何本地用户都能创建/改写 smartroute.rules，
# 而守护进程是 root、会照着文件内容执行 route add -net <内容>。
# 以前只有 cmd_rule add 校验 CIDR，应用路径什么都不看——
# 等于把"以 root 添加任意路由"的能力开放给任何本地用户。
_vc() {   # valid_cidr 的判定
    bash -c "
        . '$T/sr.sh'
        valid_cidr '$1' && echo OK || echo NO
    " 2>/dev/null
}
for good in "10.0.0.0/8" "192.168.1.0/24" "172.16.0.0/12" "10.1.2.3/32"; do
    [ "$(_vc "$good")" = "OK" ] && ok "合法 CIDR 通过: $good" || bad "合法 CIDR 被拒: $good"
done
# 前缀 0 要拒：0.0.0.0/0 是默认路由，应用它会抢走全部流量
[ "$(_vc '0.0.0.0/0')" = "NO" ] && ok "拒绝 0.0.0.0/0（会抢默认路由）" || bad "放了 0.0.0.0/0"
for badc in "10.0.0.0/33" "10.0.0.0" "foo" "10.0.0.0/8; rm -rf /tmp/x" "10.0.0.0/-1" "999.1.1.1/8"; do
    [ "$(_vc "$badc")" = "NO" ] && ok "拒绝非法 CIDR: $badc" || bad "非法 CIDR 被放过: $badc"
done
# 接口也要校验：写个不存在的接口名，route add 会失败但守护进程每轮都重试
_vd() {
    bash -c "
        . '$T/sr.sh'
        valid_dev '$1' && echo OK || echo NO
    " 2>/dev/null
}
[ "$(_vd en0)" = "OK" ] && ok "真实接口通过" || bad "真实接口被拒"
[ "$(_vd 不存在的接口)" = "NO" ] && ok "假接口被拒" || bad "假接口被放过"
[ "$(_vd 'en0; id')" = "NO" ] && ok "带注入的接口名被拒" || bad "注入字符串被放过"

# apply_rules 遇到非法条目要跳过并记账，不能静默应用。
# 注意 apply_rules 第一行就要求 root，而 run() 里不是 root——
# 所以这里像第 13 节那样自己起 bash 并在 source 之后把 PATH 设好（脚本第 2 行会重置 PATH）。
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
EOF
chmod +x "$T/bin/id"
# log() 写文件不打印，所以把 LOG_FILE 指到临时文件再读它
out="$(bash -c "
    . '$T/sr.sh'
    export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
    LOG_FILE='$T/sr.log'
    printf '%s\n' '10.0.0.0/8 en0' '0.0.0.0/0 en0' '垃圾 en0' '192.168.2.0/24 假接口' > '$T/r.txt'
    RULES_FILE='$T/r.txt'
    apply_rules
    cat '$T/sr.log' 2>/dev/null
" 2>&1 | grep -v 'Broken pipe')"
echo "  --- apply_rules 日志 ---"
printf '%s\n' "$out" | sed 's/^/    /' | head -6
# 判据要看日志内容，不能 grep 内部变量名（want 是 local，永远不会输出）。
# 每条非法条目都该有一条"跳过"日志；合法那条不该出现在跳过日志里。
_skipped() { printf '%s\n' "$out" | grep "跳过非法条目" | grep -c "$1"; }
[ "$(_skipped '0.0.0.0/0')" = "1" ] && ok "0.0.0.0/0 被跳过并记账" || bad "0.0.0.0/0 的处理不对"
[ "$(_skipped '垃圾')" = "1" ] && ok "垃圾 CIDR 被跳过并记账" || bad "垃圾 CIDR 的处理不对"
[ "$(_skipped '假接口')" = "1" ] && ok "假接口条目被跳过并记账" || bad "假接口条目的处理不对"
[ "$(_skipped '10.0.0.0/8')" = "0" ] && ok "合法条目没被误跳过" || bad "合法条目被误跳过了"
printf '%s\n' "$out" | grep -q "有 3 条非法条目已跳过" \
    && ok "汇总计数正确（3 条）" || bad "汇总计数不对"
# 合法条目应该真的去添加路由（这里 route 是真实的，会失败，但日志应有尝试痕迹）
printf '%s\n' "$out" | grep -q "跳过非法条目 '10.0.0.0/8" && bad "合法条目被当成非法" || ok "合法条目走了应用路径"
rm -f /tmp/_r.txt

echo
echo "== 15. balance_on 中断保护：Ctrl-C 不许把网络留在卡死状态 =="
# 实测故障链（用户报"开启双网并发后网络卡死"）：
#   1. pf 规则加载，网络被规则搞坏
#   2. balance_validate 跑 10 次 nc，全灭时要 60-90 秒（每次等满超时+3 种兜底）
#   3. 用户看到"命令卡住" → 按 Ctrl-C
#   4. 没有 trap → pf 规则留着，网络继续卡着
#   5. 用户自己想到 balance off 才恢复
# 日志对得上：既无"验证失败"也无"已开启"，但 pf 确实是 smartroute 开的。
_bo_int() {
    bash -c "
        . '$T/sr.sh'
        export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        export MOCK_LOG='$MOCK_LOG'
        balance_off() { echo 'BALANCE_OFF_CALLED' >> \"\$MOCK_LOG\"; }
        _balance_on_interrupt
        echo SHOULD_NOT_REACH
    " 2>&1
}
: > "$MOCK_LOG"
out="$(_bo_int)"
grep -q "BALANCE_OFF_CALLED" "$MOCK_LOG" \
    && ok "中断时调用 balance_off（还原 pf 规则）" || bad "中断时没有还原 pf，网络会继续卡着"
echo "$out" | grep -q "正在还原 pf 规则" \
    && ok "告知用户正在还原（那一刻用户最需要看到这句）" || bad "中断时无声，用户不知道网络会不会回来"
echo "$out" | grep -q "SHOULD_NOT_REACH" \
    && bad "中断后还在继续跑，trap 没退出" || ok "中断后立即退出，不再往下执行"
bash -c "
    . '$T/sr.sh'
    export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
    export MOCK_LOG='$MOCK_LOG'
    balance_off() { :; }
    _balance_on_interrupt
" >/dev/null 2>&1
[ "$?" = "130" ] && ok "退出码 130（128+SIGINT，shell 约定）" || bad "退出码不是 130"

# trap 必须在加载 pf **之前**挂上，否则加载完到挂 trap 之间被中断照样漏
_trap_line=$(grep -n "trap '_balance_on_interrupt' INT TERM" "$SRC" | head -1 | cut -d: -f1)
# 必须取 trap **之后**的第一处 pf 加载。文件里共 4 处（cmd_watch /
# balance_on / balance_reevaluate / balance_weight_reevaluate），
# 取全局第一处会落到 cmd_watch（第 1043 行），那当然比 trap 行号小。
_pf_line=$(awk -v t="$_trap_line" 'NR>t && /pfctl -a "\$PF_ANCHOR" -f "\$PF_ANCHOR_FILE"/{print NR; exit}' "$SRC")
if [ -n "$_trap_line" ] && [ -n "$_pf_line" ] && [ "$_trap_line" -lt "$_pf_line" ]; then
    ok "trap 挂在加载 pf 之前（第 $_trap_line 行 < 第 $_pf_line 行）"
else
    bad "trap 挂在加载 pf 之后或没挂（${_trap_line} / ${_pf_line}），中断会漏还原"
fi
# 成功路径必须摘掉 trap，否则它会渗到后续命令里。
#
# ⚠️ 原来用跨行 grep 模式（模式里含换行）。而 grep 的多行 pattern 在 bash 里
# 被拆成多个 pattern，语义是 **OR** 不是 AND——于是
# `state_set balance_winner "$only"` 和 `trap - INT TERM` 各自存在即命中，
# **完全不验证二者相邻**。而已知 trap - INT TERM 在源码里有 8 处，
# 所以这条断言基本恒绿。实测：在两者之间插 3 行无关代码（bash -n 通过），
# 断言仍然绿。
#
# 而"相邻"正是它想守的属性：不相邻就意味着 trap 会渗到后续命令里。
# 改成取 winner 行的**下一行**再比对，行号差必须是 1。
_winner_line=$(grep -n 'state_set balance_winner "\$only"' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$_winner_line" ]; then
    _next_line=$(awk -v n="$_winner_line" 'NR==n+1' "$SRC")
    if [ "$_next_line" = "    trap - INT TERM" ]; then
        ok "成功路径摘掉 trap（紧跟在 winner 之后，不渗到后续命令）"
    else
        bad "成功路径没紧跟着摘 trap（下一行是: ${_next_line}）"
    fi
else
    bad "找不到 state_set balance_winner \"\$only\""
fi
# 每条 die/回滚分支都要先摘 trap 再走，否则 trap 会在进程退出前多余地跑一次
_n_clear=$(grep -c "trap - INT TERM; balance_off quiet" "$SRC")
[ "$_n_clear" -ge 3 ] \
    && ok "回滚分支都先摘 trap（$_n_clear 处）" \
    || bad "回滚分支漏摘 trap：只有 $_n_clear 处，期望 >=3"

echo "== 16. 验证快速失败：网络真坏时不许跑满 60-90 秒 =="
# 10 次 nc 全超时要 60-90 秒，用户看到的就是"卡住"然后 Ctrl-C。
# 前 4 次全灭就该收手——早还原，用户根本感觉不到卡过。
grep -q 'if \[ "\$i" -eq 4 \] && \[ "\$ok" -eq 0 \]' "$SRC" \
    && ok "前 4 次全灭即快速失败" || bad "没有快速失败，网络坏时要白等 60-90 秒"
export MOCK_NET_OK=0
: > "$MOCK_LOG"
run 'balance_validate en0 192.168.2.36 en1 192.168.1.5' >/dev/null 2>&1
nc_calls=$(grep -c "^nc " "$MOCK_LOG")
# 4 轮 × 每轮最多 3 种兜底（53/443/curl），curl 不在 nc mock 里但会真跑；
# 关键是比较：快速失败应显著少于 10 轮的量
if [ "$nc_calls" -le 8 ]; then
    ok "网络不通时只探了 $nc_calls 次就收手（不是跑满 10 轮）"
else
    bad "网络不通时探了 $nc_calls 次，白等太久，用户会 Ctrl-C"
fi
export MOCK_NET_OK=1

echo "== 17. 已知缺口必须被写明，不能假装不存在 =="
# balance_on 有"加载后验证 + 失败自动还原"，但两条重测路径
# （balance_reevaluate / balance_weight_reevaluate）没有。想过补，实测不可行：
#   · 10 个探测，快几秒慢几十秒，而守护进程每轮都跑这条路径
#   · 单次网络抖动就可能把用户的双网并发永久关掉（balance_off 会置 BALANCE=0，
#     守护进程不会自己开回来）——太鲁莽
#   · mock_fastest.sh 没有 netstat mock，validate 读真实计数器而 mock 的 nc
#     不产生真实流量，验证必然失败——7 条断言假失败
# 所以这里不断言"已修复"，而是断言"缺口被明确记录、且没有半吊子实现"。
# 半吊子实现（加了验证但误伤率很高）比没有验证更糟：用户会莫名失去功能。
# 必须排除注释行：那段"已知缺口"的注释里就写着 balance_validate 这个词
# （解释为什么没加），不排除会自己打自己。
_reeval_v=$(awk '/^balance_reevaluate\(\) \{/,/^\}/' "$SRC" | grep -v '^[[:space:]]*#' | grep -c "balance_validate")
_wreeval_v=$(awk '/^balance_weight_reevaluate\(\) \{/,/^\}/' "$SRC" | grep -v '^[[:space:]]*#' | grep -c "balance_validate")
[ "$_reeval_v" = "0" ] \
    && ok "balance_reevaluate 没有偷偷加验证（误伤率高，见注释）" \
    || bad "balance_reevaluate 加了验证：单次抖动就会关掉用户的双网并发"
[ "$_wreeval_v" = "0" ] \
    && ok "balance_weight_reevaluate 同样没加" || bad "balance_weight_reevaluate 加了验证"
grep -q "已知缺口（不要假装这里没有）" "$SRC" \
    && ok "缺口在代码里被明确记录" \
    || bad "缺口没有记录，下一个人会以为已经安全"
grep -q "mock_fastest.sh 没有 netstat mock" "$SRC" \
    && ok "记录了为什么没加（可复现的理由，不是借口）" \
    || bad "没记录原因，后人无法判断该不该补"

echo
echo "结果: $PASS 通过, $FAIL 失败"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)

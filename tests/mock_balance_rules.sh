#!/bin/bash
# mock 测试：apply_rules / write_pf_rules / cmd_rule
# 用假的 route/netstat/pfctl/ifconfig/networksetup 验证逻辑，不动真实系统
set -u
SRC="/Users/mm/Pictures/smartroute/smartroute.sh"
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
  # 计数器每次 +1000 模拟流量增长；MOCK_FROZEN 指定的接口不增长
  f="$MOCK_BYTES_DIR/$2"
  b=$(cat "$f" 2>/dev/null || echo 0)
  if [ "${MOCK_FROZEN:-}" != "$2" ]; then b=$((b + 1000)); echo "$b" > "$f"; fi
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
grep -q "nat on" "$T/etc/pf.anchor" && bad "同网段不应写 NAT" || ok "同网段不写 NAT（源地址天然合法）"
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
echo "$out" | grep -q "TCP 测试连接只有" && ok "网络不通时明确报错（含成功数）" || bad "网络不通未报错: $out"
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
echo "结果: $PASS 通过, $FAIL 失败"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)

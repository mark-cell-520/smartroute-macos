#!/bin/bash
# 端到端：route 往 stdout 喷垃圾（旧版 bug 场景）时，判定链仍能正确得出 wifi_ok=1
set -u
SRC="/Users/mm/Pictures/smartroute/smartroute.sh"
T=/tmp/sr_e2e
rm -rf "$T"; mkdir -p "$T/bin" "$T/state" "$T/etc" "$T/log" "$T/run"
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# route mock：完全复刻真实 macOS 行为——成功/失败都往 stdout 打印
cat > "$T/bin/route" <<'EOF'
#!/bin/bash
case "$1" in
  add)    echo "add host $3: gateway $5" ;;
  delete) echo "delete host $3" ;;
  "-n")   echo "    gateway: 192.168.1.1" ;;
esac
exit 0
EOF
cat > "$T/bin/ping" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo 0
exit 0
EOF
cat > "$T/bin/pfctl" <<'EOF'
#!/bin/bash
case "$*" in *"-s info"*) echo "Status: Enabled" ;; *"-s rules"*) echo "pass out all" ;; esac
exit 0
EOF
cat > "$T/bin/netstat" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-rn" ]; then
    echo "Destination        Gateway            Flags    Refs    Use    Netif"
    echo "default            192.168.1.1        UGScg     12      0      en0"
fi
exit 0
EOF
chmod +x "$T/bin/"*
export MOCK_ROUTES="$T/routes.txt"

sed -e "s|^CONF=.*|CONF=\"$T/etc/smartroute.conf\"|" \
    -e "s|^USER_CONF=.*|USER_CONF=\"$T/etc/user.conf\"|" \
    -e "s|^RULES_FILE=.*|RULES_FILE=\"$T/etc/smartroute.rules\"|" \
    -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log/smartroute.log\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/lock\"|" \
    -e "s|^PF_ANCHOR_FILE=.*|PF_ANCHOR_FILE=\"$T/etc/pf.anchor\"|" \
    -e "s|^PF_STATE_FILE=.*|PF_STATE_FILE=\"$T/state/pf.state\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"

run() {
    bash -c "
        export PATH='$T/bin:$PATH'
        export MOCK_ROUTES='$MOCK_ROUTES'
        . '$T/sr.sh'
        $1
    " 2>&1
}

echo "== 1. 污染场景下判定值必须干净 =="
out="$(run 'probe_dev en1 192.168.1.1' | sed -n 1p)"
[ "$out" = "ok" ] && ok "route 喷 7 行垃圾，判定行仍是干净的 ok" || bad "得到: [$out]"

echo "== 2. update_streak 收到脏值不能卡住 =="
out="$(run 'update_streak wifi "add host 1.1.1.1: gateway 192.168.1.1"')"
[ "$out" = "0" ] && ok "脏值被当作未知处理（计数归 0）" || bad "得到: $out"

echo "== 3. 完整 watch 周期：同网段双接口都应判通 =="
# 连续跑 3 个周期（OK_N=2，滞回后应稳定为 1）
for i in 1 2 3; do run 'cmd_watch' >/dev/null; done
eth_ok="$(awk -F= '$1=="eth_ok"{print $2}' "$T/state/state")"
wifi_ok="$(awk -F= '$1=="wifi_ok"{print $2}' "$T/state/state")"
se="$(awk -F= '$1=="streak_eth"{print $2}' "$T/state/state")"
sw="$(awk -F= '$1=="streak_wifi"{print $2}' "$T/state/state")"
echo "    eth_ok=$eth_ok wifi_ok=$wifi_ok streak_eth=$se streak_wifi=$sw"
[ "$eth_ok" = "1" ] && ok "以太网判定为有外网" || bad "以太网判定错误"
[ "$wifi_ok" = "1" ] && ok "Wi-Fi 判定为有外网（修复前这里是 0）" || bad "Wi-Fi 仍被误判为无外网"
[ "$se" -ge 2 ] && [ "$sw" -ge 2 ] && ok "滞回计数正常累积" || bad "计数异常"

echo "== 4. 探测明细仍然可用 =="
detail="$(run 'probe_dev en1 192.168.1.1' | sed -n 2p)"
echo "    明细: $detail"
echo "$detail" | grep -q "ping=" && ok "明细包含分层探测结果" || bad "明细缺失"

echo "== 5. 真失败时仍能正确判负（不能一律放水）=="
for c in ping nc curl; do
cat > "$T/bin/$c" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$T/bin/$c"
done
out="$(run 'probe_dev en1 192.168.1.1' | sed -n 1p)"
[ "$out" = "fail" ] && ok "网络真不通时仍判 fail" || bad "得到: $out"

echo
echo "结果: $PASS 通过, $FAIL 失败"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)

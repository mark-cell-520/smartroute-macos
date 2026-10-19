#!/bin/bash
# mock 测试：watch 的安全阀与规则应用集成（不影响原有选路逻辑）
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)/smartroute.sh"
T=/tmp/sr_mock3
rm -rf "$T"; mkdir -p "$T/bin" "$T/state" "$T/etc" "$T/log" "$T/run"
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

cat > "$T/bin/route" <<'EOF'
#!/bin/bash
echo "route $*" >> "$MOCK_LOG"
exit 0
EOF
cat > "$T/bin/pfctl" <<'EOF'
#!/bin/bash
echo "pfctl $*" >> "$MOCK_LOG"
case "$*" in
  *"-s info"*) echo "Status: ${MOCK_PF_STATUS:-Disabled}" ;;
  *"-s rules"*) [ "${MOCK_ANCHOR_LOADED:-0}" = "1" ] && echo "pass out route-to { (en0 192.168.1.1) (en1 192.168.1.1) } round-robin" ;;
esac
exit 0
EOF
cat > "$T/bin/netstat" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-rn" ]; then cat "$MOCK_ROUTES" 2>/dev/null; fi
exit 0
EOF
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo 0
exit 0
EOF
chmod +x "$T/bin/"*
: > "$T/routes.txt"
cat > "$T/routes.txt" <<'EOF'
Destination        Gateway            Flags    Refs    Use    Netif
default            192.168.1.1        UGScg     12      0      en1
EOF
export MOCK_LOG="$T/calls.log"
: > "$MOCK_LOG"; export MOCK_ROUTES="$T/routes.txt"
export MOCK_PF_STATUS=Enabled MOCK_ANCHOR_LOADED=1

# 被测脚本：路径改到 /tmp，剥掉入口和硬编码 PATH
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

runwatch() {   # 在隔离环境里跑一次 watch
    bash -c "
        export PATH='$T/bin:$PATH'
        export MOCK_LOG='$MOCK_LOG' MOCK_ROUTES='$MOCK_ROUTES'
        export MOCK_PF_STATUS='$MOCK_PF_STATUS' MOCK_ANCHOR_LOADED='$MOCK_ANCHOR_LOADED'
        . '$T/sr.sh'
        BALANCE='$1'
        cmd_watch
    " 2>&1
}

echo "== 1. BALANCE=0 时 watch 不碰 pf =="
: > "$MOCK_LOG"
out="$(runwatch 0)"
grep -q "pfctl" "$MOCK_LOG" && bad "BALANCE=0 不应调用 pfctl" || ok "BALANCE=0 不调用 pfctl"
echo "$out" | grep -q "eth=" && ok "watch 正常输出状态行" || { bad "watch 输出"; echo "$out"; }
grep -q "route add -net\|route delete -net" "$MOCK_LOG" && bad "BALANCE=0 不应动静态路由" || ok "BALANCE=0 不动静态路由"

echo "== 2. BALANCE=1 + 两接口判定都 ok → 不动 pf =="
: > "$MOCK_LOG"
out="$(runwatch 1)"
grep -q "pfctl -a com.apple/smartroute -F all" "$MOCK_LOG" && bad "健康时不应关闭并发" || ok "健康时不关闭并发"
grep -q "route add -net\|route delete -net" "$MOCK_LOG" && bad "无规则时不应动静态路由" || ok "无规则不动静态路由"

echo "== 3. BALANCE=1 + 以太网判定失败 → 安全阀关闭并发 =="
# 让以太网探测失败：把 eth 的连续计数置负，超过 FAIL_N
printf 'streak_eth=-5\nstreak_wifi=2\neth_ok=1\nwifi_ok=1\n' > "$T/state/state"
: > "$MOCK_LOG"
out="$(runwatch 1)"
grep -q "pfctl -a com.apple/smartroute -F all" "$MOCK_LOG" && ok "安全阀清空 pf anchor" || { bad "安全阀清空 anchor"; echo "$out"; }
grep -q "pfctl -d" "$MOCK_LOG" && ok "安全阀关闭我们开启的 pf" || echo "  ℹ️ pf 非本工具开启，未关闭（符合预期）"
(grep -q "BALANCE=0" "$T/etc/user.conf" 2>/dev/null || grep -q "BALANCE=0" "$T/etc/smartroute.conf" 2>/dev/null) \
    && ok "安全阀把 BALANCE 置 0" || bad "安全阀置 BALANCE=0"
grep -q "并发分流安全阀" "$T/log/smartroute.log" && ok "安全阀写日志" || bad "安全阀写日志"

echo "== 4. 规则文件有内容时 watch 应用静态路由 =="
printf 'streak_eth=0\nstreak_wifi=0\n' > "$T/state/state"
printf '# 规则\n10.0.0.0/8 en0\n192.168.9.0/24 en1\n' > "$T/etc/smartroute.rules"
rm -f "$T/etc/user.conf"
: > "$MOCK_LOG"
out="$(runwatch 0)"
grep -q "route add -net 10.0.0.0/8" "$MOCK_LOG" && ok "应用规则 10.0.0.0/8" || { bad "应用规则 10.0.0.0/8"; cat "$MOCK_LOG"; }
grep -q "route add -net 192.168.9.0/24" "$MOCK_LOG" && ok "应用规则 192.168.9.0/24" || bad "应用规则 192.168.9.0/24"

echo "== 5. 规则删除后 watch 清理静态路由 =="
printf '# 规则\n192.168.9.0/24 en1\n' > "$T/etc/smartroute.rules"
printf '192.168.9         link#16            UCS        2      0      en1\n' >> "$T/routes.txt"
: > "$MOCK_LOG"
runwatch 0 >/dev/null
grep -q "route delete -net 10.0.0.0/8" "$MOCK_LOG" && ok "删除失效规则的路由" || { bad "删除失效规则"; cat "$MOCK_LOG"; }
grep -q "route add -net 192.168.9.0/24" "$MOCK_LOG" && bad "已应用的规则不重复添加" || ok "已应用的规则不重复添加"

echo "== 6. BALANCE=1 但 pf 规则丢失 → 重新加载 =="
printf 'streak_eth=2\nstreak_wifi=2\n' > "$T/state/state"
export MOCK_ANCHOR_LOADED=0
printf 'ext1 = "en0"\npass out all\n' > "$T/etc/pf.anchor"
: > "$MOCK_LOG"
out="$(runwatch 1)"
grep -q "pfctl -a com.apple/smartroute -f" "$MOCK_LOG" && ok "规则丢失时重新加载" || { bad "规则丢失重新加载"; cat "$MOCK_LOG"; }
grep -q "pfctl -e" "$MOCK_LOG" && ok "重新加载前确保 pf 开启" || bad "重新加载前开启 pf"

echo
echo "结果: $PASS 通过, $FAIL 失败"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)

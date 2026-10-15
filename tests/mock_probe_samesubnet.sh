#!/bin/bash
# 复现并验证：同网段双宿主 + 与守护进程并发时，探测不再误判
set -u
SRC="/Users/mm/Pictures/smartroute/smartroute.sh"
T=/tmp/sr_mock4
rm -rf "$T"; mkdir -p "$T/bin" "$T/state" "$T/etc" "$T/log" "$T/run"
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# route mock：add 失败时同时往 stdout/stderr 打印（模拟最脏的情况）
cat > "$T/bin/route" <<'EOF'
#!/bin/bash
case "$1" in
  add)
      if [ "${MOCK_ROUTE_ADD_FAIL:-0}" = "1" ]; then
          echo "add host $3: gateway $5: File exists"
          echo "route: writing to routing socket: add host $3: gateway $5: File exists" >&2
          exit 1
      fi
      exit 0 ;;
  "-n")
      # route -n get <ip>
      if [ "${MOCK_EXISTING_GW:-}" != "" ]; then
          echo "   route to: $4"
          echo "destination: $4"
          echo "    gateway: $MOCK_EXISTING_GW"
          echo "  interface: en1"
      fi
      exit 0 ;;
  delete) exit 0 ;;
  get)
      if [ "${MOCK_EXISTING_GW:-}" != "" ]; then echo "    gateway: $MOCK_EXISTING_GW"; fi
      exit 0 ;;
esac
exit 0
EOF
cat > "$T/bin/pfctl" <<'EOF'
#!/bin/bash
case "$*" in *"-s info"*) echo "Status: Enabled" ;; *"-s rules"*) echo "pass out all" ;; esac
exit 0
EOF
cat > "$T/bin/netstat" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-rn" ] && cat "$MOCK_ROUTES" 2>/dev/null
exit 0
EOF
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo 0
exit 0
EOF
cat > "$T/bin/ping" <<'EOF'
#!/bin/bash
[ "${MOCK_NET_OK:-1}" = "1" ] && exit 0
exit 1
EOF
chmod +x "$T/bin/"*
cat > "$T/routes.txt" <<'EOF'
Destination        Gateway            Flags    Refs    Use    Netif
default            192.168.1.1        UGScg     12      0      en1
EOF
export MOCK_ROUTES="$T/routes.txt"

# 被测脚本
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

run() {   # run <shell 代码>
    bash -c "
        export PATH='$T/bin:$PATH'
        export MOCK_ROUTES='$MOCK_ROUTES' MOCK_ROUTE_ADD_FAIL='${MOCK_ROUTE_ADD_FAIL:-0}' MOCK_EXISTING_GW='${MOCK_EXISTING_GW:-}' MOCK_NET_OK='${MOCK_NET_OK:-1}'
        . '$T/sr.sh'
        $1
    " 2>&1
}

echo "== 1. 复现原 bug：add 失败且无现成路由 → 判定 fail =="
export MOCK_ROUTE_ADD_FAIL=1 MOCK_EXISTING_GW=""
out="$(run 'probe_dev en1 192.168.1.1' | sed -n 1p)"
[ "$out" = "fail" ] && ok "无现成路由时正确判定 fail（判定行干净：${out}）" || bad "期望 fail，得到: $out"
detail="$(run 'probe_dev en1 192.168.1.1' | sed -n 2p)"
echo "    明细: ${detail:-（无）}"

echo "== 2. 修复核心：add 报已存在但现成路由网关一致 → 应通过 =="
export MOCK_ROUTE_ADD_FAIL=1 MOCK_EXISTING_GW="192.168.1.1"
out="$(run 'probe_dev en1 192.168.1.1' | sed -n 1p)"
[ "$out" = "ok" ] && ok "同网关现成路由被复用，探测通过" || bad "期望 ok，得到: $out"

echo "== 3. 现成路由是别的网关（不同上网路径）→ 仍判 fail =="
export MOCK_EXISTING_GW="192.168.31.1"
out="$(run 'probe_dev en1 192.168.1.1' | sed -n 1p)"
[ "$out" = "fail" ] && ok "不同网关不复用，正确判 fail" || bad "期望 fail，得到: $out"
export MOCK_EXISTING_GW=""

echo "== 4. route 往 stdout 吐垃圾也不能污染探测结果 =="
export MOCK_ROUTE_ADD_FAIL=0
out="$(run 'probe_dev en1 192.168.1.1' | tr '\n' '|')"
first="$(printf '%s' "$out" | cut -d'|' -f1)"
nlines="$(printf '%s' "$out" | tr -cd '|' | wc -c | tr -d ' ')"
[ "$first" = "ok" ] && [ "$nlines" = "2" ] && ok "探测判定行是 ok，无 route 噪音" || bad "输出被污染: [$out]"
export MOCK_ROUTE_ADD_FAIL=1 MOCK_EXISTING_GW="192.168.1.1"
out="$(run 'probe_dev en1 192.168.1.1' | tr '\n' '|')"
first="$(printf '%s' "$out" | cut -d'|' -f1)"
nlines="$(printf '%s' "$out" | tr -cd '|' | wc -c | tr -d ' ')"
[ "$first" = "ok" ] && [ "$nlines" = "2" ] && ok "失败分支判定行也是 ok，无 route 噪音" || bad "输出被污染: [$out]"

echo "== 5. balance_on 与守护进程抢锁 =="
# 用一个真实存活的进程占锁（kill 是 bash 内建，mock 无效）
sleep 60 & LOCKPID=$!
mkdir -p "$T/run/lock" && echo "$LOCKPID" > "$T/run/lock/pid"
out="$(run 'balance_on' | tail -1)"
echo "$out" | grep -q "另一个 smartroute 正在运行" && ok "被占用时明确报错（而非静默退出）" || bad "锁提示缺失: $out"
kill "$LOCKPID" 2>/dev/null; rm -rf "$T/run/lock"

echo "== 6. 同网关时给出带宽提示 =="
export MOCK_ROUTE_ADD_FAIL=0
out="$(run 'balance_on')"
echo "$out" | grep -q "网关相同" && ok "提示同网关不会提升带宽" || bad "缺少同网关提示"
echo "$out" | grep -q "双网并发要求两个接口都有外网" && bad "探测被误判为失败" || ok "同网段下两个接口探测都通过"

echo
echo "结果: $PASS 通过, $FAIL 失败"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)

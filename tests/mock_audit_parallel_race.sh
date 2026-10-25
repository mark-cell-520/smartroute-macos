#!/bin/bash
# 回归测试：probe_dev 判定必须与明细一致——明细说成功，判定就必须是 ok
#
# 曾经的病灶：并行探测层的 marker 复核只置 ping_ok/tcp_ok/tls_ok，
# **没有把 ok 置 0**，而 probe_out 的最终判定只看 ok
#
# 位置：smartroute.sh:920-937（ping）、942-961（TCP）、963-981（TLS），三处同一毛病
#
#     if _probe_wait_any "$_T" "ping_" "$_pt_s"; then
#         ping_ok=1; ok=0            # ← 只有这条路径把 ok 置 0
#         _probe_kill_pids "$_pids"
#     else
#         wait 2>/dev/null           # ← 超时后仍把后台探测等完
#     fi
#     for t in $_ptargets; do [ -f "$_T/ping_$t" ] && { ping_ok=1; break; }; done
#     #                            ^^^^ 这里只记 ping_ok，没有 ok=0
#
# 而 probe_out 的最终判定只看 ok（987 行）。于是：等待窗口没赶上、但探测其实
# 成功了的时候，明细打 "ping=1"，结论打 "fail"——**同一份输出里两句话互相矛盾**，
# 且结论是错的（假失败）。
#
# 为什么这不是理论问题：_probe_wait_any 的墙上时长并不等于标称秒数。它用
# `_t0=$SECONDS` + `SECONDS - _t0 >= tmo` 判超时，而 SECONDS 是整数秒计数器，
# 实际等待均匀分布在 (0, tmo] 之间（实测 30 次：146ms ~ 1025ms，19 次 <600ms）。
# ping 自己的超时是 PING_TIMEOUT=800ms，也就是说**一半以上的成功回包会落在
# 等待窗口之外**。触发条件完全真实：
#     · 网络禁了前两个探测目标（223.5.5.5 / 119.29.29.29）的 ICMP → 走并行分支
#     · 其余目标通，但 RTT 有几百毫秒（劣化链路/远距离/拥塞——正是本工具要发现的场景）
#
# 用户可见后果：一条好线被判成"无外网"。cmd_watch 里再叠加当场确认
# （RECONFIRM_TIMES=2），一个周期内记满 3 笔失败 → streak ≤ -FAIL_N →
#  eth_ok=0 → 立刻从好线切走。smartroute test -v 会同时打印
# "ping=1 tcp=0 tls=0" 和 "无外网"，用户无法自证链路是好的。
#
# 运行: bash tests/mock_audit_parallel_race.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

SRC="$(pwd)/smartroute.sh"
T="$(mktemp -d /tmp/sr_pr.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/log" "$T/run" "$T/etc"
export MOCK_ROUTE_LOG="$T/routes.log"; : > "$MOCK_ROUTE_LOG"

cat > "$T/bin/route" <<'EOF'
#!/bin/bash
echo "route $*" >> "$MOCK_ROUTE_LOG"
case "$*" in
    add*)    exit 0 ;;
    *get*)   printf '   route to: 1.1.1.1\n destination: 1.1.1.1\n  interface: en0\n' ;;
esac
exit 0
EOF
# ping 替身：前两个目标 ICMP 被墙（走并行分支），其余目标 RTT 500ms 后回包
cat > "$T/bin/ping" <<'EOF'
#!/bin/bash
tgt=""
for a in "$@"; do tgt="$a"; done
case "$tgt" in
  223.5.5.5|119.29.29.29) exit 1 ;;      # 这两个目标的 ICMP 被防火墙丢掉
esac
sleep 0.5                                # 劣化链路：RTT 500ms（ping -W 800 放得下）
exit 0
EOF
for c in nc curl; do
cat > "$T/bin/$c" <<'EOF'
#!/bin/bash
exit 1
EOF
done
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo 0
exit 0
EOF
cat > "$T/bin/pfctl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/"*

sed -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log/l\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/l\"|" \
    -e "s|^SVC_ORDER_BAK=.*|SVC_ORDER_BAK=\"$T/state/svc\"|" \
    -e "s|^PF_ANCHOR_FILE=.*|PF_ANCHOR_FILE=\"$T/etc/anchor\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"
pd() {   # $1=脚本  ->  stdout: 两行（判定/明细）
    PATH="$T/bin:$PATH" bash -c ". '$1'; probe_dev en0 192.168.1.1" 2>/dev/null
}

N=20
echo "== 1. 链路通（前两个目标禁 ICMP、其余 RTT 500ms）：判定必须是 ok =="
nfail=0; ncontra=0
for i in $(seq 1 $N); do
    out="$(pd "$T/sr.sh")"
    v="$(printf '%s\n' "$out" | sed -n 1p)"
    d="$(printf '%s\n' "$out" | sed -n 2p)"
    [ "$v" = "fail" ] && nfail=$((nfail+1))
    # 不变量：明细里任一层报成功，判定就不能是 fail
    if [ "$v" = "fail" ] && printf '%s' "$d" | grep -qE '(ping|tcp|tls)=1'; then
        ncontra=$((ncontra+1))
    fi
    [ "$i" -le 3 ] && printf '    第 %d 次: 判定=%s 明细=%s\n' "$i" "$v" "$d"
done
echo "    ..."
echo "    $N 次里判 fail 的: $nfail 次；其中明细报成功（自相矛盾）的: $ncontra 次"
[ "$nfail" -eq 0 ] \
    && ok "链路通时 20 次全判 ok（不再有假失败）" \
    || bad "出现 $nfail 次假失败——并行层 marker 复核漏了 ok=0"
[ "$ncontra" -eq 0 ] \
    && ok "判定与明细从不相悖" \
    || bad "有 $ncontra 次明细报成功却判 fail"

echo
echo "== 2. 静态 lint：三处 marker 复核都必须把 ok 置 0 =="
# 行为测试靠时序，天生可能碰不上；这条不依赖时序，改动当即被发现。
for layer in ping tcp tls; do
    if awk '/^probe_dev\(\)/,/^}/' "$SRC" | grep -q "${layer}_ok=1; ok=0"; then
        ok "${layer} 层的复核把 ok 一起置 0"
    else
        bad "${layer} 层只置 ${layer}_ok，判定仍会与明细矛盾"
    fi
done

echo
echo "== 3. 端到端：好线不能被假失败赶走（守卫）=="
# 第 3 节用独立的一套 mock：route 替身把"正在探测哪个接口"记下来，ping 替身
# 按它决定回包快慢——en0 慢到等待窗口之外（必然假失败），en1 快（必然及时）。
# 这正是真实竞态的两个方向，这里只是把它们固定住，便于断言。
mkdir -p "$T/bin2"
cat > "$T/bin2/route" <<'EOF'
#!/bin/bash
case "$*" in
    add*)
        prev=""
        for a in "$@"; do [ "$prev" = "-interface" ] && printf '%s\n' "$a" > "$MOCK_CUR_IFACE"; prev="$a"; done
        exit 0 ;;
    *get*) printf '  interface: %s\n' "$(cat "$MOCK_CUR_IFACE" 2>/dev/null || echo en0)" ;;
esac
exit 0
EOF
cat > "$T/bin2/ping" <<'EOF'
#!/bin/bash
tgt=""
for a in "$@"; do tgt="$a"; done
case "$tgt" in
  223.5.5.5|119.29.29.29) exit 1 ;;
esac
if [ "$(cat "$MOCK_CUR_IFACE" 2>/dev/null || echo en0)" = "en1" ]; then sleep 0.05; else sleep 1.15; fi
exit 0
EOF
# nc / curl：这个网络禁 TCP（只放 ICMP），否则 TCP 层会直接把接口判活
for c in nc curl; do
cat > "$T/bin2/$c" <<'EOF'
#!/bin/bash
exit 1
EOF
done
cat > "$T/bin2/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo 0
exit 0
EOF
cat > "$T/bin2/pfctl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin2/"*
export MOCK_CUR_IFACE="$T/cur_iface"; echo en0 > "$MOCK_CUR_IFACE"
: > "$T/state/state"
printf 'streak_eth=-1\nstreak_wifi=2\nlast_switch=1699990000\n' > "$T/state/state"
e2e() {
    bash -c "
        export PATH='$T/bin2:/usr/bin:/bin:/usr/sbin:/sbin'
        export LOG_FILE='$T/log/e2e.log' STATE_FILE='$T/state/state' MOCK_NOW=1700000000
        export MOCK_CUR_IFACE='$MOCK_CUR_IFACE'
        . '$T/sr.sh'
        trap - EXIT INT TERM HUP
        export NOTIFY=0 AUTO_WIFI_POWER=0 BALANCE=0 WIFI_FAILOVER=0 MODE=auto
        export PING_TIMEOUT=1000 RECONFIRM_DELAY=1 RECONFIRM_TIMES=2 RECONFIRM_BUDGET=6
        find_active() { ACTIVE_ETH_DEV=en0;  ACTIVE_ETH_SVC='Ethernet'
                        ACTIVE_WIFI_DEV=en1; ACTIVE_WIFI_SVC='Wi-Fi'; }
        default_dev() { echo en0; }
        do_switch() { printf 'SWITCH %s\n' \"\$1\" >> '$T/calls'; }
        measure_throughput() { return 0; }
        measure_latency() { return 0; }
        apply_rules() { :; }
        wifi_failover_if_needed() { :; }
        cmd_watch
    " 2>&1
}
: > "$T/calls"
for i in 1 2 3; do
    echo en0 > "$MOCK_CUR_IFACE"          # 复位：上一轮最后探的是 en1
    out="$(e2e)"
    printf '    周期 %d: %s\n' "$i" "$(printf '%s' "$out" | tail -1)"
    printf '      en0 明细: %s\n' "$(echo en0 > "$MOCK_CUR_IFACE"; PATH="$T/bin2:$PATH" bash -c ". '$T/sr.sh'; probe_dev en0 192.168.1.1" 2>/dev/null | sed -n 2p)"
    grep -q "SWITCH en1" "$T/calls" && break
done
echo "    --- do_switch 调用 ---"; sed 's/^/      /' "$T/calls"
# 断言方向与病灶相反：链路好就**不该**被切走，也不该把 eth_ok 写成 0。
# 这条是端到端的护栏——它同时覆盖"假失败"和"假失败引发的错误切换"。
grep -q "SWITCH" "$T/calls" \
    && bad "链路明明是好的（明细 ping=1）却被切换：$(tr '\n' ' ' < "$T/calls")" \
    || ok "没有发生切换（好线不被冤枉）"
grep -q "eth_ok=0" "$T/state/state" \
    && bad "state 里 eth_ok 被写成 0（守护进程认定好线没有外网）" \
    || ok "state 里 eth_ok 保持 1"

echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

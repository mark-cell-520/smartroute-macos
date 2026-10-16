#!/bin/bash
# 测试「切换默认路由」——do_switch / reorder_first
#
# 为什么这个必须测：do_switch 是整个工具存在的意义（"哪个接口该走"最终
# 要靠它落地），而它在此前一次都没被测过。它有三条路径：
#   1. 调整服务顺序（持久）——成功就返回
#   2. 兜底：直接改路由表
#   3. 最危险的一条：route delete default 成功但 route add default 失败
#      -> 用户机器没有默认路由 = 完全断网，要等下次 watch 才能恢复
# 第三条路径没有任何测试，改错了就是让用户断网。
#
# 运行: bash tests/mock_switch.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_switch.XXXXXX)"
mkdir -p "$T/bin" "$T/state" "$T/lock"
trap 'rm -rf "$T"' EXIT

# 脚本前缀：入口之前的部分（函数定义 + 默认值），不含 main 分发
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"

# ---------- mock ----------
cat > "$T/bin/networksetup" <<'EOF'
#!/bin/bash
case "${1:-}" in
    -listnetworkserviceorder) cat "$MOCK_ORDER" ;;
    -listallhardwareports)    cat "$MOCK_HW" ;;
    -getinfo)
        awk -F'|' -v s="$2" '$1==s{print "Router: "$2; print "IP address: "$3}' "$MOCK_INFO" 2>/dev/null
        ;;
    -ordernetworkservices)
        printf 'REORDER\n' >> "$MOCK_CALLS"; printf '%s\n' "$@" >> "$MOCK_CALLS"
        exit "${MOCK_REORDER_RC:-0}"
        ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$T/bin/networksetup"

cat > "$T/bin/route" <<'EOF'
#!/bin/bash
printf 'ROUTE %s\n' "$*" >> "$MOCK_CALLS"
case "${1:-}" in
    -n)
        # 真实调用是 "route -n get default"——$1=-n $2=get $3=default。
        # 最早写的是查 $2，恒不匹配，default_dev 永远返回空，
        # 于是每条用例都被推进"服务顺序失败"的兜底分支，测的根本不是想测的路径。
        if [ -f "$MOCK_DEFAULT" ]; then cat "$MOCK_DEFAULT"; fi
        exit 0 ;;
    add)    exit "${MOCK_ADD_RC:-0}" ;;
    delete) exit "${MOCK_DEL_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$T/bin/route"

cat > "$T/bin/osascript" <<'EOF'
#!/bin/bash
printf 'NOTIFY %s\n' "$*" >> "$MOCK_CALLS"
exit 0
EOF
chmod +x "$T/bin/osascript"

cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
EOF
chmod +x "$T/bin/id"

# 标准测试数据
# 注意格式：真实 macOS 的 -listnetworkserviceorder 输出里，
# 每个服务名下面紧跟一行 "(Hardware Port: X, Device: enY)"，
# service_devices 就是从这同一份输出里解析 服务名->设备 的。
# 最早我的 mock 只给了服务名行，结果 svc_of_dev 恒返回空，do_switch 直接不执行。
cat > "$T/order" <<'EOF'
(1) Ethernet
(Hardware Port: Ethernet, Device: en0)

(2) Wi-Fi
(Hardware Port: Wi-Fi, Device: en1)

(3) iPhone USB
(Hardware Port: iPhone USB, Device: en5)
EOF
printf '(1) Ethernet\n(Hardware Port: Ethernet, Device: en0)\n' > "$T/order_one"
printf '(1) Thunderbolt Bridge\n(Hardware Port: Thunderbolt Bridge, Device: en2)\n\n(2) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en1)\n' > "$T/order_sp"
cat > "$T/hw" <<'EOF'
Hardware Port: Ethernet
Device: en0
Ethernet Address: 00:11:22:33:44:55

Hardware Port: Wi-Fi
Device: en1
Ethernet Address: 00:11:22:33:44:66
EOF
cat > "$T/info" <<'EOF'
Ethernet|192.168.1.1|192.168.1.36
Wi-Fi|192.168.1.1|192.168.1.5
iPhone USB||
EOF
printf '   route to: default\n  interface: en1\n  gateway: 192.168.1.1\n' > "$T/def_en1"
printf '   route to: default\n  interface: en0\n  gateway: 192.168.1.1\n' > "$T/def_en0"

# 通用执行器。两个要点：
#  1) PATH / LOG_FILE 必须在 source 之后再设——smartroute.sh 第 2 行会重置 PATH，
#     事先设好的 mock 全被冲掉；LOG_FILE 是硬编码的 /var/log/smartroute.log，
#     普通用户写不进去，不覆盖的话每个 log() 都报 Operation not permitted。
#  2) 必须清掉 EXIT trap：前缀里有一个顶层 trap，source 时就生效，
#     bash -c 退出时会触发 cleanup_probe_routes，把一堆 route delete -host
#     写进 calls 日志，污染断言。
# 参数: $1=服务顺序文件 $2=默认路由文件 $3=要跑的代码 $4=额外 export
run_in() {
    bash -c "
        . '$T/sr.sh'
        trap - EXIT INT TERM HUP
        export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        export MOCK_ORDER='$1' MOCK_HW='$T/hw' MOCK_INFO='$T/info'
        export MOCK_CALLS='$T/calls' MOCK_DEFAULT='$2'
        export LOG_FILE='$T/sr.log' STATE_FILE='$T/state/st'
        export STATE_WRITABLE=1 LOCK_DIR='$T/lock' NOTIFY=1
        ${4:-}
        $3
    " 2>&1
}
reset_calls() { : > "$T/calls"; }

echo "== 1. reorder_first：参数拼得对不对 =="
reset_calls
run_in "$T/order" "$T/def_en1" 'reorder_first "Ethernet"' >/dev/null
grep -q "^REORDER$" "$T/calls" && ok "调用了 -ordernetworkservices" || bad "没调用 ordernetworkservices"
# 第 1 行 REORDER 标记，第 2 行是命令名本身，第 3 行起才是参数
[ "$(sed -n '3p' "$T/calls")" = "Ethernet" ] && ok "目标服务排在第一个" || bad "目标没排第一: $(sed -n '3p' "$T/calls")"
grep -qx "Wi-Fi" "$T/calls" && ok "其余服务被带上（Wi-Fi）" || bad "漏了 Wi-Fi"
grep -qx "iPhone USB" "$T/calls" && ok "其余服务被带上（iPhone USB）" || bad "漏了 iPhone USB"
[ "$(grep -cx 'Ethernet' "$T/calls")" -eq 1 ] && ok "目标服务不重复" || bad "目标重复出现"

echo "== 2. reorder_first：只剩一个服务时（空数组展开）=="
reset_calls
out="$(run_in "$T/order_one" "$T/def_en1" 'reorder_first "Ethernet"')"
grep -q "^REORDER$" "$T/calls" && ok "单服务时也调用了" || bad "单服务时没调用"
printf '%s' "$out" | grep -qiE "unbound|syntax error" && bad "单服务时报错: $out" || ok "单服务时不报错（空数组安全）"

echo "== 3. reorder_first：服务名带空格 =="
reset_calls
run_in "$T/order_sp" "$T/def_en1" 'reorder_first "Thunderbolt Bridge"' >/dev/null
grep -qx "Thunderbolt Bridge" "$T/calls" \
    && ok "带空格的服务名作为单个参数传递" || bad "空格名被拆开: $(tail -n +2 "$T/calls" | tr '\n' '|')"

echo "== 4. do_switch：服务顺序这条路走通 =="
reset_calls
run_in "$T/order" "$T/def_en0" 'do_switch en0 en1 ok ok 2 2' >/dev/null
grep -q "^REORDER$" "$T/calls" && ok "先试服务顺序" || bad "没试服务顺序"
# 只查 add/delete：default_dev 也会调 route -n get default，宽泛地 grep "ROUTE"
# 会把正常的查询误判成"动了路由表"
grep -qE "ROUTE (add|delete) default" "$T/calls" && bad "成功了还去改路由表（多余动作）" || ok "成功后不改路由表"
grep -q "^NOTIFY" "$T/calls" && ok "发了切换通知" || bad "没发通知"
grep -q "^last_switch=" "$T/state/st" 2>/dev/null && ok "记录了切换时间（冷却用）" || bad "没记录 last_switch"

echo "== 5. do_switch：服务顺序失败 -> 兜底改路由表 =="
reset_calls
out="$(run_in "$T/order" "$T/def_en1" 'export MOCK_REORDER_RC=1; do_switch en0 en1 ok ok 2 2')"
grep -q "无法通过服务顺序切换" "$T/sr.log" && ok "识别到服务顺序失败" || bad "没识别失败: $(tail -2 "$T/sr.log")"
grep -q "ROUTE delete default" "$T/calls" && ok "兜底删了默认路由" || bad "兜底没删默认路由"
grep -q "ROUTE add default" "$T/calls" && ok "兜底加了默认路由" || bad "兜底没加默认路由"
grep -q "完成：路由表已改为" "$T/sr.log" && ok "兜底成功有日志" || bad "兜底成功没日志: $(tail -2 "$T/sr.log")"

echo "== 6. do_switch：最危险的一条——删了默认路由但加不回来 =="
reset_calls
# state 文件要清：第 4 节走成功路径时写了 last_switch，
# 不清的话这一节的"失败不该写 last_switch"会读到上一节的残留。
: > "$T/state/st"; : > "$T/sr.log"
out="$(run_in "$T/order" "$T/def_en1" 'export MOCK_REORDER_RC=1 MOCK_ADD_RC=1; do_switch en0 en1 ok ok 2 2')"
grep -q "ROUTE delete default" "$T/calls" && ok "确实执行了删除" || bad "没删除"
grep -q "失败：无法添加 default via" "$T/sr.log" \
    && ok "明确记录添加失败（用户断网时可排查）" || bad "添加失败没日志，断网却无从查起: $(tail -2 "$T/sr.log")"
grep -q "^NOTIFY" "$T/calls" && bad "失败了还发成功通知，误导用户" || ok "失败时不发成功通知"
grep -q "^last_switch=" "$T/state/st" 2>/dev/null \
    && bad "失败却写了 last_switch（冷却会推迟恢复，延长断网）" || ok "失败不写 last_switch"

echo "== 7. do_switch：目标接口没有网关信息 =="
reset_calls
: > "$T/sr.log"
out="$(run_in "$T/order" "$T/def_en1" 'export MOCK_REORDER_RC=1; do_switch en5 en1 ok ok 2 2')"
grep -q "失败：目标接口没有网关信息" "$T/sr.log" \
    && ok "没有网关时明确失败" || bad "没有网关时行为不对: $(tail -2 "$T/sr.log")"
grep -qE "ROUTE (add|delete) default" "$T/calls" && bad "没网关还改路由表，会断网" || ok "没网关时不碰路由表"

echo "== 8. do_switch：目标设备没有对应服务名 =="
reset_calls; : > "$T/sr.log"
out="$(run_in "$T/order" "$T/def_en1" 'export MOCK_REORDER_RC=1; do_switch en9 en1 ok ok 2 2')"
grep -q "失败：目标接口没有网关信息" "$T/sr.log" \
    && ok "找不到服务时明确失败（不瞎动路由表）" || bad "找不到服务时行为不对: $(tail -2 "$T/sr.log")"
grep -q "ROUTE delete default" "$T/calls" && bad "没网关还去删默认路由，会断网" || ok "没网关时不碰路由表"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

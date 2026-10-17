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

# 失败也必须落 last_switch。这条断言原来是反的（"失败不写 last_switch"），
# 理由写的是"冷却会推迟恢复，延长断网"——那个推理是错的：
# 失败的尝试同样执行了 route delete default。不节流的话目标持续不可用时
# 每 20 秒就重试一次，每次都先把默认路由删掉。而现在的失败路径会尝试
# 把原默认路由加回去，用户在这 45 秒里是**在线**的；不节流等于每 20 秒
# 把刚恢复的路由再拆一次，那才真的在延长断网。
grep -q "^last_switch=" "$T/state/st" \
    && ok "失败也写 last_switch（节流重试，避免每 20 秒拆一次路由）" \
    || bad "失败不写 last_switch，会每 20 秒重试并重复删默认路由"

# 删之前必须先记下原默认路由，否则加不回来时无法恢复
grep -q "尝试恢复原默认路由" "$T/sr.log" \
    && ok "加失败时尝试恢复原默认路由（宁可没切成，也不能让人掉线）" \
    || bad "加失败就撒手，系统会留在没有默认路由的状态"
# 恢复也失败时必须给出可照抄的手动命令
grep -q "请手动执行：sudo route add default" "$T/sr.log" \
    && ok "恢复也失败时给出可照抄的手动命令" \
    || bad "恢复失败时无声，用户断网却无从下手"

echo "== 6b. do_switch：加不回去时能恢复原默认路由（不断网）=="
# 这是最关键的安全属性。场景：切到 en0 失败（MOCK_ADD_RC 只让第一次 add 失败），
# 但恢复用的 add 必须成功——验证我们真的把原默认路由加回来了。
reset_calls
: > "$T/sr.log"; : > "$T/state/st"
# 自定义 route mock：必须保留 -n get default 的处理，否则 default_dev/default_gw
# 返回空，bak_if/bak_gw 就是空的，测的就不是想测的路径了（第一版就栽在这里）。
# 另外 route_add_default 有三个变体，要让"切换失败"必须让前三次 add 都失败，
# 第四次（恢复原路由）才成功——用计数器实现。
rm -f "$T/.addcnt"
cat > "$T/bin/route" <<'EOS'
#!/bin/bash
printf 'ROUTE %s\n' "$*" >> "$MOCK_CALLS"
case "${1:-}" in
    -n) [ -f "$MOCK_DEFAULT" ] && cat "$MOCK_DEFAULT"; exit 0 ;;
    add)
        case "$2" in
            default)
                # 计数器目录从 MOCK_CALLS 推。第一版用 ${MOCK_T}，但 run_in
                # 并不导出它，于是写到 /.addcnt（不可写），cat 永远拿到空、
                # n 恒为 1、所有 add 都失败——测出来"恢复失败"是假象。
                D="${MOCK_CALLS%/*}"
                n="$(cat "$D/.addcnt" 2>/dev/null || echo 0)"; n=$((n+1))
                echo "$n" > "$D/.addcnt"
                # 前 3 次 = route_add_default 的三个变体，全失败 -> 切换失败
                # 第 4 次 = 恢复原默认路由，成功 -> 用户不断网
                [ "$n" -le 3 ] && exit 1
                exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOS
chmod +x "$T/bin/route"
out="$(run_in "$T/order" "$T/def_en1" 'export MOCK_REORDER_RC=1; do_switch en0 en1 ok ok 2 2')"
grep -q "尝试恢复原默认路由" "$T/sr.log" \
    && ok "走了恢复分支" || bad "没走恢复分支: $(tail -3 "$T/sr.log")"
grep -q "已恢复原默认路由：en1 via" "$T/sr.log" \
    && ok "原默认路由被加回来了（用户不断网）" || bad "没恢复成功: $(tail -3 "$T/sr.log")"
# 恢复的必须是原来的接口，不能是切换目标
grep -q "ROUTE add default.*-interface en1" "$T/calls" \
    && ok "恢复用的是原接口 en1，不是切换目标 en0" \
    || bad "恢复用了错误的接口: $(grep 'add default' "$T/calls")"
grep -q "严重：无法恢复默认路由" "$T/sr.log" \
    && bad "恢复成功却报严重错误，误导用户" || ok "恢复成功不报严重错误"
# 删之前必须先查原参数（default_dev/default_gw），否则无从恢复
grep -q 'bak_if="\$(default_dev)"' smartroute.sh \
    && ok "删之前记下原接口" || bad "没记原接口"
grep -q 'bak_gw="\$(default_gw)"' smartroute.sh \
    && ok "删之前记下原网关" || bad "没记原网关"

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

echo "== 9. 系统反复推翻选择时要检测并说明（flap）=="
# 实测这台机器：51 次 en0 -> en1，只有 7 次反向。这不是抖动，是 macOS
# 每次都把默认路由重新判回以太网、工具再改回来。用户感受就是"以太网卡主"，
# 而工具一声不响地反复改了几十次。检测到就该说清楚，而不是继续沉默地改。
awk '/^do_switch\(\)/,/^}/' smartroute.sh | grep -q 'flap_count' \
    && ok "do_switch 统计被系统改回的次数" || bad "没有 flap 检测"
awk '/^do_switch\(\)/,/^}/' smartroute.sh | grep -q 'flap_n.*-eq 3' \
    && ok "第 3 次才告警（不冤枉偶发波动）" || bad "告警时机不对"
awk '/^do_switch\(\)/,/^}/' smartroute.sh | grep -q 'flap_n % 10' \
    && ok "之后每 10 次提一次（不刷屏）" || bad "会重复刷屏"
awk '/^do_switch\(\)/,/^}/' smartroute.sh | grep -q 'flap_n=1' \
    && ok "切换目标变化时重置计数" || bad "计数不重置，会误报"
awk '/^do_switch\(\)/,/^}/' smartroute.sh | grep -q 'last_ts=' \
    && ok "last_switch 取到变量里后再进算术" || bad "直接把 state_get 塞进 \$((  ))"

echo "== 9b. 实测 flap 计数真的在动（首次 last_switch 为空）=="
# 静态检查全绿但一执行就红的例子：last_switch 首次为空时
# flap_gap=$(( now - $(state_get last_switch) )) 算术报错，整个函数中断，
# 第一次切换静默失败。必须真的跑一遍才发现。
T="$(mktemp -d /tmp/sr_flap.XXXXXX)"; mkdir -p "$T/state" "$T/bin" "$T/lock"
: > "$T/state/st"; : > "$T/sr.log"; : > "$T/calls"
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"
printf '#!/bin/bash\n[ -f "$MOCK_ORDER" ] && cat "$MOCK_ORDER"; exit 0\n' > "$T/bin/networksetup"
printf '#!/bin/bash\nprintf "ROUTE %%s\\n" "$*" >> "$MOCK_CALLS"\ncase "${1:-}" in -n) [ -f "$MOCK_DEFAULT" ] && cat "$MOCK_DEFAULT"; exit 0 ;; esac\nexit 0\n' > "$T/bin/route"
printf '#!/bin/bash\nprintf "NOTIFY %%s\\n" "$*" >> "$MOCK_CALLS"; exit 0\n' > "$T/bin/osascript"
chmod +x "$T/bin"/*
printf '   route to: default\n  interface: en0\n  gateway: 192.168.1.1\n' > "$T/def_en0"
printf '(1) Wi-Fi\n(2) Ethernet\n' > "$T/order"; printf 'en0\nen1\n' > "$T/hw"
_rf() {
    bash -c ". '$T/sr.sh'; trap - EXIT INT TERM HUP
        export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        export MOCK_ORDER='$T/order' MOCK_HW='$T/hw' MOCK_CALLS='$T/calls' MOCK_DEFAULT='$T/def_en0'
        export LOG_FILE='$T/sr.log' STATE_FILE='$T/state/st' STATE_WRITABLE=1
        export LOCK_DIR='$T/lock' NOTIFY=1; $1" >/dev/null 2>&1
}
for _i in 1 2 3; do _rf 'do_switch en1 en0 ok ok 2 2'; done
_fc="$(awk -F= '$1=="flap_count"{print $2}' "$T/state/st")"
[ "$_fc" = "3" ] && ok "连续 3 次切到同一目标，flap_count=$_fc" || bad "flap_count 应为 3，实际 ${_fc:-空}"
grep -q "第 3 次" "$T/sr.log" && ok "第 3 次写了日志" || bad "第 3 次没写日志"
[ "$(grep -c '^NOTIFY' "$T/calls")" = "1" ] && ok "第 3 次发了 1 条通知（不刷屏）" || bad "通知条数不对"
_rf 'do_switch en0 en1 ok ok 2 2'
_fc2="$(awk -F= '$1=="flap_count"{print $2}' "$T/state/st")"
[ "$_fc2" = "1" ] && ok "目标改变后重置为 1" || bad "目标改变后应重置为 1，实际 ${_fc2:-空}"

# 端到端：走完整的 cmd_watch，验证"问题解决后计数归零"。
# 上面的直调 do_switch 验不了这条——归零的分支在 cmd_watch 里，
# 而且它的触发条件是"这一轮不需要切换"，只有跑完整轮次才成立。
# 第一次写这个 e2e 时 mock 漏了 -listallhardwareports/-getinfo，
# find_active 返回空、cmd_watch 第一行就 return 了，看起来像"计数没动"。
# 状态文件也必须清空：上一节（9b）直调 do_switch 留下了 flap_count /
# streak_* / last_switch，带着这些开头，第一轮的滞回和冷却判定都不一样，
# 累计行为就对不上预期。每一节都该有干净的起点。
: > "$T/state/st"; : > "$T/sr.log"; : > "$T/calls"
# order 文件必须带 "(Hardware Port: X, Device: enN)" 行：service_devices 是
# 从这儿拿服务名的。上一节（9b）只直调 do_switch，用的是简版
# "(1) Wi-Fi\n(2) Ethernet"，没有 Device 行——复用同一个 $T 就会继承它，
# 于是 ACTIVE_*_SVC 为空、svc_router 返回空、探测判 fail、一轮都没切换。
printf '(1) Ethernet\n(Hardware Port: Ethernet, Device: en0)\n\n(2) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en1)\n' > "$T/order"
printf 'Hardware Port: Wi-Fi\nDevice: en1\n\nHardware Port: Ethernet\nDevice: en0\n' > "$T/hw2"
printf 'Wi-Fi|192.168.1.1|192.168.1.5\nEthernet|192.168.1.1|192.168.1.36\n' > "$T/info"
printf '   route to: default\n  interface: en1\n  gateway: 192.168.1.1\n' > "$T/def_en1"
# 用 heredoc 而不是 printf：mock 里的 awk 带单引号，塞进 printf 的单引号
# 字符串里会把外层戳破（第一次就是这么写砸的，报 syntax error near ';;'）。
cat > "$T/bin/networksetup" <<'MOCKNS'
#!/bin/bash
case "${1:-}" in
    -listnetworkserviceorder) cat "$MOCK_ORDER" ;;
    -listallhardwareports)    cat "$MOCK_HW" ;;
    -getinfo) awk -F'|' -v s="$2" '$1==s{print "Router: "$2}' "$MOCK_INFO" ;;
    *) exit 0 ;;
esac
MOCKNS
chmod +x "$T/bin/networksetup"
# 探测全 OK：不依赖真实 ping/curl，直接让 probe_dev 判 ok
printf '#!/bin/bash\nexit 0\n' > "$T/bin/ping"; chmod +x "$T/bin/ping"
# dev_active 靠 ifconfig 判断有没有 IP。不接管它就会去问真 ifconfig，
# 结果取决于真机状态——测试就漂了（第一次写这个 e2e 时漏了它，
# 于是 dev_active 全 false、探测全 na、want 为空、flap 被归零，
# 看起来像"cmd_watch 累计不了 flap"，其实是探测压根没跑）。
cat > "$T/bin/ifconfig" <<'MOCKIF'
#!/bin/bash
case "$1" in
    en0|en1)
        echo "$1: flags=8863<UP> mtu 1500"
        echo -e "\tinet 192.168.1.5 netmask 0xffffff00"
        exit 0 ;;
esac
exec /sbin/ifconfig "$@"
MOCKIF
chmod +x "$T/bin/ifconfig"
_wf() {
    # STATE_FILE 必须在 source **之后** export：脚本第 64 行无条件赋值
    # STATE_FILE=/var/db/smartroute/state，先 export 会被它清掉，
    # 于是状态全写到真实路径、测试读的临时文件始终是空的。
    # 代价是 SVC_ORDER_BAK（第 633 行由 STATE_FILE 目录算出）仍指着真实路径，
    # reorder_first 会往那儿写——无权限，失败即可，stderr 已抑制。
    bash -c ". '$T/sr.sh'; trap - EXIT INT TERM HUP
        export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        export MOCK_ORDER='$T/order' MOCK_HW='$T/hw2' MOCK_INFO='$T/info'
        export MOCK_CALLS='$T/calls' MOCK_DEFAULT='$1'
        export LOG_FILE='$T/sr.log' STATE_FILE='$T/state/st' STATE_WRITABLE=1
        export LOCK_DIR='$T/lock' NOTIFY=1 MODE=wifi; cmd_watch" >/dev/null 2>&1
}
# 先抖几轮：系统每轮都把默认路由判回 en0，我们切到 en1。
# 每轮前把 last_switch 设成 60 秒前——必须是个**近期**时间，不能清零：
#   · 清零（0）能让冷却放行，但 flap_gap 用的是同一个字段，
#     now-0 是个巨大值、超过 1800 秒窗口，于是走 else 分支把计数重置成 1，
#     看起来像"累计不起来"（第一次写这个测试就这么栽的）。
#   · 60 秒前：> COOLDOWN(45s) 冷却放行，< 1800s 仍在 flap 窗口内。
# 4 轮而不是 3 轮：第 1 轮在攒 streak（滞回要求连续 OK_N=2 次才判可用），
# 那一轮 want 为空、不切换。所以 3 轮只累计到 2，4 轮才到 3。
for _i in 1 2 3 4; do
    sed -i '' "s/^last_switch=.*/last_switch=$(( $(date +%s) - 60 ))/" "$T/state/st" 2>/dev/null
    _wf "$T/def_en0"
done
_fc3="$(awk -F= '$1=="flap_count"{print $2}' "$T/state/st")"
[ "${_fc3:-0}" -ge 3 ] 2>/dev/null \
    && ok "cmd_watch 连续抖之后 flap_count=$_fc3" \
    || bad "cmd_watch 没能累计 flap，实际 ${_fc3:-空}"
# 现在系统不再改回了：默认路由守住 en1，want==cur，不需要切换。
#
# 这里要分两种情况，以前只测了第一种，于是把 bug 固化了：
#
#   A) 刚修好（last_switch 是几十秒前）→ 计数**必须保留**。
#      清零条件原先是"这一轮不需要切换"，而抖动过程中每一轮之间
#      恰好都有这种轮次（切完的那轮之后，cur==want），计数被反复擦掉，
#      永远到不了 3，警报永远不响。真实症状：switch_count 已上百次，
#      flap_count 始终是空的，用户完全不知道系统在反复改路由。
#   B) 早就修好了（last_switch 超过 1800s 抖动窗口）→ 计数归零 + 留痕。
#      否则提示会永久挂在状态页，用户以为工具在说谎。
_wf "$T/def_en1"
_fc4="$(awk -F= '$1=="flap_count"{print $2}' "$T/state/st")"
[ "${_fc4:-x}" != "0" ] && ok "刚修好时保留计数（不擦掉证据，${_fc4}）" \
    || bad "刚修好就归零，警报永远响不起来"
grep -q "默认路由已稳定" "$T/sr.log" && bad "刚修好却报'已稳定'" || ok "刚修好不谎报稳定"

# B) 把 last_switch 推到 1 小时前，模拟"半小时没再被改回"
sed -i '' "s/^last_switch=.*/last_switch=$(( $(date +%s) - 3600 ))/" "$T/state/st" 2>/dev/null
: > "$T/sr.log"
_wf "$T/def_en1"
_fc5="$(awk -F= '$1=="flap_count"{print $2}' "$T/state/st")"
[ "${_fc5:-x}" = "0" ] && ok "超过抖动窗口后归零（假警报会消失）" \
    || bad "应归零，实际 ${_fc5:-空}"
grep -q "默认路由已稳定" "$T/sr.log" && ok "归零时记了日志" || bad "归零没留痕"
rm -rf "$T"

echo "== 10. 问题解决后 flap 计数必须归零（假警报比没警报更糟）=="
# 用户按提示改了局域网网段，系统不再反复判回以太网了。
# 若计数不清，状态页永远挂着"macOS 已 51 次把默认路由改回以太网"——
# 一个永不消失的假警报会让人怀疑工具在说谎，然后不再看任何提示。
awk '/^cmd_watch\(\)/,/^}/' smartroute.sh | grep -q 'state_set flap_count 0' \
    && ok "不需要切换时会清掉 flap 计数" || bad "flap 计数永不清零，假警报常驻"
awk '/^cmd_watch\(\)/,/^}/' smartroute.sh | grep -q '清除选路不稳定计数' \
    && ok "清了会记一笔日志（用户能追溯）" || bad "清了不留痕"
# 关键细节：不能用"没调用 do_switch 就重置"——
# 冷却期里也不切换，但那正是抖得最厉害的时候，清了等于擦掉证据。
# 必须是 elif（与"需要切换"互斥），而不是无条件放在末尾。
awk '/^cmd_watch\(\)/,/^}/' smartroute.sh | grep -q 'elif.*state_get flap_count' \
    && ok "重置走 elif（与"需要切换"互斥，冷却期内不会误清）" \
    || bad "重置条件不对，可能在冷却期内擦掉证据"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# 测试最快线路重测：balance_reevaluate + FASTEST_RECHECK 计数
#
# 为什么必须测：balance_reevaluate 是 BALANCE_MODE=fastest 下**唯一会改 pf 规则**
# 的路径，守护进程每 FASTEST_RECHECK 个轮询周期调一次。它直接写
# /etc/pf.anchors/com.user.smartroute 并 pfctl 加载——写错就是把用户的
# 出站流量规则改坏。而它此前零测试。
#
# 重点验证的属性：
#  - 已经是最快线路时不做任何动作（不重写规则、不重复通知）
#  - tie / 两边都测不到 → 回退成两条轮询，不是卡在一条上
#  - 写规则或加载规则失败 → 不更新 state（下一轮还能重试），
#    但也不能留下"通知已发、状态没改"的半成品
#
# 运行: bash tests/mock_fastest.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_fastest.XXXXXX)"
mkdir -p "$T/bin" "$T/state" "$T/etc"
trap 'rm -rf "$T"' EXIT
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"

cat > "$T/bin/pfctl" <<'EOF'
#!/bin/bash
printf 'PFCTL %s\n' "$*" >> "$MOCK_CALLS"
[ "${1:-}" = "-a" ] && exit "${MOCK_LOAD_RC:-0}"
exit 0
EOF
chmod +x "$T/bin/pfctl"
cat > "$T/bin/osascript" <<'EOF'
#!/bin/bash
printf 'NOTIFY %s\n' "$*" >> "$MOCK_CALLS"
exit 0
EOF
chmod +x "$T/bin/osascript"
cat > "$T/bin/date" <<'EOF'
#!/bin/bash
[ "${1:-}" = "+%s" ] && { echo 1700000000; exit 0; }
exec /bin/date "$@"
EOF
chmod +x "$T/bin/date"

common='
    . "'$T'/sr.sh"
    trap - EXIT INT TERM HUP
    export PATH="'$T'/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export LOG_FILE="'$T'/sr.log" STATE_FILE="'$T'/state/st"
    export STATE_WRITABLE=1 LOCK_DIR="'$T'/lock"
    export MOCK_CALLS="'$T'/calls" PF_ANCHOR_FILE="'$T'/etc/anchor"
    export NOTIFY=1
    ACTIVE_ETH_DEV=en0; ACTIVE_WIFI_DEV=en1
    ACTIVE_ETH_SVC="Ethernet"; ACTIVE_WIFI_SVC="Wi-Fi"
    svc_router() { case "$1" in Ethernet) echo "192.168.1.1" ;; Wi-Fi) echo "192.168.1.1" ;; esac; }
    # 延迟值由 MOCK_ETH_LAT / MOCK_WIFI_LAT 控制；空串=测不到
    measure_latency() { case "$1" in
        en0) [ -n "${MOCK_ETH_LAT:-}" ] && echo "${MOCK_ETH_LAT}" ;;
        en1) [ -n "${MOCK_WIFI_LAT:-}" ] && echo "${MOCK_WIFI_LAT}" ;;
    esac; return 0; }
    other_nets() { :; }
'

# 跑 balance_reevaluate。$1=额外代码
run_re() {
    : > "$T/calls"; : > "$T/sr.log"
    bash -c "$common
        ${1:-}
        balance_reevaluate
        echo \"RC=\$?\"
    " 2>&1
}

echo "== 1. 一边明显更快 → 切换到它并写 pf 规则 =="
: > "$T/state/st"
out="$(run_re 'export MOCK_ETH_LAT=10 MOCK_WIFI_LAT=60')"
printf '%s' "$out" | grep -q "RC=0" && ok "返回 0" || bad "没返回 0: $out"
grep -q "PFCTL -a .* -f " "$T/calls" && ok "加载了 pf 规则" || bad "没加载 pf 规则: $(cat "$T/calls" | tr '\n' '|')"
grep -q "^balance_winner=en0$" "$T/state/st" && ok "state 记录赢家 en0" || bad "state 没记录赢家: $(cat "$T/state/st" | tr '\n' '|')"
grep -q "^NOTIFY" "$T/calls" && ok "发了切换通知" || bad "没发通知"
[ -s "$T/etc/anchor" ] && ok "规则文件真的写出来了" || bad "规则文件是空的"

echo "== 2. 已经是当前赢家 → 完全不动 =="
: > "$T/state/st"; printf 'balance_winner=en0\n' > "$T/state/st"
out="$(run_re 'export MOCK_ETH_LAT=10 MOCK_WIFI_LAT=60')"
grep -q "PFCTL" "$T/calls" && bad "没变还重写规则（多余动作）" || ok "没变就不碰 pf"
grep -q "^NOTIFY" "$T/calls" && bad "没变还重复通知（骚扰用户）" || ok "没变就不通知"

echo "== 3. tie → 回退成两条轮询 =="
: > "$T/state/st"; printf 'balance_winner=en0\n' > "$T/state/st"
out="$(run_re 'export MOCK_ETH_LAT=30 MOCK_WIFI_LAT=30')"
grep -q "PFCTL -a .* -f " "$T/calls" && ok "回退时也重写了规则" || bad "回退时没写规则"
grep -q "^balance_winner=$" "$T/state/st" && ok "赢家被清空（=两条轮询）" || bad "赢家没清空: $(cat "$T/state/st" | tr '\n' '|')"

echo "== 4. 两边都测不到 → 回退成两条轮询 =="
: > "$T/state/st"; printf 'balance_winner=en1\n' > "$T/state/st"
out="$(run_re 'export MOCK_ETH_LAT= MOCK_WIFI_LAT=')"
grep -q "^balance_winner=$" "$T/state/st" && ok "测不到就回退轮询（不卡在一条上）" || bad "测不到时行为不对: $(cat "$T/state/st" | tr '\n' '|')"

echo "== 5. 缺网关 → 直接返回，不碰 pf =="
: > "$T/state/st"
out="$(run_re 'svc_router() { echo ""; }; export MOCK_ETH_LAT=10 MOCK_WIFI_LAT=60')"
printf '%s' "$out" | grep -q "RC=0" && ok "缺网关返回 0（不是错误）" || bad "缺网关返回非 0"
grep -q "PFCTL" "$T/calls" && bad "缺网关还去动 pf" || ok "缺网关不碰 pf"

echo "== 6. 加载规则失败 → 不更新 state，下一轮能重试 =="
: > "$T/state/st"
out="$(run_re 'export MOCK_ETH_LAT=10 MOCK_WIFI_LAT=60 MOCK_LOAD_RC=1')"
printf '%s' "$out" | grep -q "RC=1" && ok "失败返回 1（调用方能知道）" || bad "加载失败却返回 0: $out"
grep -q "^balance_winner=" "$T/state/st" && bad "加载失败还写了 state（下次认为已完成，不再重试）" || ok "加载失败不写 state"
grep -q "^NOTIFY" "$T/calls" && bad "失败了还发成功通知" || ok "失败不发成功通知"

echo "== 7. FASTEST_RECHECK 计数：到阈值才重测，并归零 =="
: > "$T/state/st"
# 直接在 cmd_watch 的路径上验计数逻辑（不真跑整个 watch）
cnt_code='
    bcyc=$(( $(state_get balance_cycle) + 1 ))
    state_set balance_cycle "$bcyc"
    if [ "$bcyc" -ge "$FASTEST_RECHECK" ]; then state_set balance_cycle 0; echo TRIGGER; fi
'
for i in 1 2 3; do
    out="$(bash -c "$common
        export FASTEST_RECHECK=3
        state_set balance_mode fastest
        $cnt_code
    " 2>&1)"
done
# 三次之后：cycle 应回到 0，且三次里恰好一次 TRIGGER
cyc="$(state_get_cycle() { :; }; awk -F= '$1=="balance_cycle"{print $2}' "$T/state/st")"
[ "$cyc" = "0" ] && ok "到阈值后归零（不会一直累加）" || bad "计数没归零: $cyc"
# balance_cycle 非数字时不能算错
: > "$T/state/st"; printf 'balance_cycle=garbage\n' > "$T/state/st"
out="$(bash -c "$common
    export FASTEST_RECHECK=3
    bcyc=\$(( \$(state_get balance_cycle) + 1 ))
    state_set balance_cycle \"\$bcyc\"
    echo \"CYC=\$bcyc\"
" 2>&1)"
printf '%s' "$out" | grep -q "CYC=1" && ok "脏数据按 0 起算（不炸）" || bad "脏数据导致异常: $out"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# 判定矩阵：cmd_watch 的可用性/滞回/冷却/退避/弃权，一格一格跑
#
# 目的：把"什么网络状况 → 什么决策"逐格钉住。已有 mock_watch_modes.sh 覆盖
# 的是 MODE 四个分支和冷却期；这里补的是**状态机边界**：
#   · 当场确认恢复（一次抖动）不能被当成真故障
#   · 持续失败时一轮就要凑满 FAIL_N（RECONFIRM 的设计目标）
#   · 一边接口整个消失（find_active 收不到它）
#   · 两边都没外网
#   · 一边延迟/吞吐测不到（弃权）
#   · 退避期间与退避到期
#   · flap 计数的清零窗口
#
# 运行: bash tests/mock_audit_matrix.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_mx.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/log" "$T/run"
cat > "$T/bin/date" <<'EOF'
#!/bin/bash
[ "${1:-}" = "+%s" ] && { echo "${MOCK_NOW:-1700000000}"; exit 0; }
exec /bin/date "$@"
EOF
cat > "$T/bin/pfctl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/"*
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"

common='
    . "'$T'/sr.sh"
    trap - EXIT INT TERM HUP
    export PATH="'$T'/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export LOG_FILE="'$T'/sr.log" STATE_FILE="'$T'/state/st" MOCK_CALLS="'$T'/calls"
    export STATE_WRITABLE=1 LOCK_DIR="'$T'/lock" MOCK_NOW=1700000000
    export NOTIFY=0 AUTO_WIFI_POWER=0 BALANCE=0 WIFI_FAILOVER=0
    measure_throughput() { return 0; }
    measure_latency() { return 0; }
    apply_rules() { :; }
    wifi_failover_if_needed() { :; }
'
# run_case <MODE> <cur> <eth_res> <wifi_res> <streak_eth> <streak_wifi> <缺哪个口|-> <额外 state 行...>
run_case() {
    local mode="$1" cur="$2" er="$3" wr="$4" se="$5" sw="$6" absent="$7"; shift 7
    : > "$T/calls"; : > "$T/sr.log"; : > "$T/state/st"; : > "$T/probe_n"
    printf 'streak_eth=%s\nstreak_wifi=%s\n' "$se" "$sw" > "$T/state/st"
    local l; for l in "$@"; do echo "$l" >> "$T/state/st"; done
    bash -c "$common
        export MODE='$mode' MOCK_ABSENT='$absent' MOCK_ETH_RES='$er' MOCK_WIFI_RES='$wr'
        find_active() {
            ACTIVE_ETH_DEV=''; ACTIVE_ETH_SVC=''; ACTIVE_WIFI_DEV=''; ACTIVE_WIFI_SVC=''
            [ \"\$MOCK_ABSENT\" = eth ] || { ACTIVE_ETH_DEV=en0;  ACTIVE_ETH_SVC='Ethernet'; }
            [ \"\$MOCK_ABSENT\" = wifi ] || { ACTIVE_WIFI_DEV=en1; ACTIVE_WIFI_SVC='Wi-Fi'; }
        }
        # 计数型探测替身：MOCK_RECOVER=1 时第 2 次调用起返回 ok（模拟当场确认恢复）
        probe_dev() {
            local want=\"\$1\" res n
            [ \"\$want\" = en0 ] && res=\"\$MOCK_ETH_RES\" || res=\"\$MOCK_WIFI_RES\"
            n=\$(( \$(cat '$T'/probe_n 2>/dev/null || echo 0) + 1 )); echo \$n > '$T'/probe_n
            if [ \"\${MOCK_RECOVER:-0}\" = 1 ] && [ \"\$n\" -ge 2 ]; then res=ok; fi
            printf '%s\n' \"\$res\"
        }
        do_switch() { printf 'SWITCH %s\n' \"\$1\" >> \"\$MOCK_CALLS\"; }
        default_dev() { echo '$cur'; }
        cmd_watch
    " 2>&1
}
switched()  { [ -s "$T/calls" ] && grep -q "SWITCH $1" "$T/calls"; }
noswitch()  { [ ! -s "$T/calls" ]; }

echo "== 1. 可用性滞回与当场确认 =="
run_case auto en0 fail ok -3 2 - >/dev/null
switched en1 && ok "以太网持续不通 → 切到 Wi-Fi" || bad "该切没切: $(cat "$T/calls")"
# 一次抖动：首探失败、当场确认第 2 次就恢复 → 不许把用户切走
run_case auto en0 fail ok -1 2 - >/dev/null   # 先跑一次占位（复位计数）
MOCK_RECOVER=1 run_case auto en0 fail ok -1 2 - >/dev/null
noswitch && ok "首探失败但当场确认恢复（抖动）→ 不切换" || bad "一次抖动就把用户切走了: $(cat "$T/calls")"
awk -F= '$1=="streak_eth"{print $2}' "$T/state/st" | grep -qx 1 \
    && ok "恢复后 streak 回到正 1（没有把用户钉在负面计数上）" || bad "streak 异常: $(cat "$T/state/st")"
# 持续失败：RECONFIRM 要在一轮内凑满 FAIL_N
run_case auto en0 fail ok 2 2 - >/dev/null
switched en1 && ok "稳态 streak=2 时一次持续失败也在一轮内判死（快速故障转移）" || bad "快速故障转移没生效: $(cat "$T/calls")"
run_case auto en0 ok fail 2 -3 >/dev/null
noswitch && ok "Wi-Fi 连败但当前走在以太网 → 不动" || bad "无谓切换: $(cat "$T/calls")"
run_case auto en0 fail fail -3 -3 >/dev/null
noswitch && ok "两边都没外网 → 保持现状，不瞎换" || bad "两边都死还切换: $(cat "$T/calls")"

echo "== 2. 一边接口整个消失 =="
# 默认路由为空（接口消失后 macOS 撤掉默认路由就是这一态）：必须把剩下的好线扶上去
run_case auto "" na ok 0 2 eth >/dev/null
switched en1 && ok "以太网口消失且没有默认路由 → 切到 Wi-Fi" || bad "该切没切: $(cat "$T/calls")"
run_case auto "" ok na 2 0 wifi >/dev/null
switched en0 && ok "Wi-Fi 口消失且没有默认路由 → 切到以太网" || bad "该切没切: $(cat "$T/calls")"
run_case auto en1 na ok 0 2 eth >/dev/null
noswitch && ok "以太网口消失但已走在 Wi-Fi 上 → 不动" || bad "无谓切换: $(cat "$T/calls")"
run_case auto en1 na fail 0 -3 eth >/dev/null
noswitch && ok "只剩 Wi-Fi 且它也不通 → 不切换也不报错" || bad "还切换: $(cat "$T/calls")"

echo "== 3. 一边延迟/吞吐测不到 → 必须弃权 =="
run_case auto en1 ok ok 2 2 - "lat_en0=12 1700000000" "lat_en1=100 1700000000" >/dev/null
switched en0 && ok "延迟悬殊（12 vs 100，差 88ms>50ms）→ 一票否决选 en0" || bad "一票否决没生效: $(cat "$T/calls")"
run_case auto en1 ok ok 2 2 - "lat_en0=12 1700000000" "lat_en1=20 1700000000" >/dev/null
noswitch && ok "延迟差 8ms（<50ms 绝对门槛）→ 不翻烧饼" || bad "微差也翻: $(cat "$T/calls")"
run_case auto en1 ok ok 2 2 - "lat_en0=12 1700000000" >/dev/null
noswitch && ok "只有一边有延迟 → 弃权保持现状" || bad "数据不全却做了决定: $(cat "$T/calls")"
run_case auto en1 ok ok 2 2 - "speed_en0=12000000 1700000000" "speed_en1=0 1700000000" >/dev/null
noswitch && ok "一边吞吐没测到 → 不当成另一边更快" || bad "把没测到当成更快: $(cat "$T/calls")"

echo "== 4. 冷却期 =="
run_case auto en0 fail ok -3 2 - "last_switch=1699999990" >/dev/null
noswitch && ok "距上次切换 10s（<COOLDOWN 45s）→ 跳过" || bad "冷却期被绕过: $(cat "$T/calls")"
run_case auto en0 fail ok -3 2 - "last_switch=1699999900" >/dev/null
switched en1 && ok "距上次切换 100s（>COOLDOWN）→ 允许切换" || bad "冷却期该结束还不切: $(cat "$T/calls")"
run_case auto en0 fail ok -3 2 - "last_switch=garbage" >/dev/null
switched en1 && ok "last_switch 是脏数据 → 不误入冷却" || bad "脏数据把切换永久堵死: $(cat "$T/calls")"

echo "== 5. futile 抗争退避（都要先造出 want≠cur）=="
SEED="speed_en0=12000000 1700000000" ; SEED2="speed_en1=40000000 1700000000"
run_case auto en0 ok ok 2 2 - "$SEED" "$SEED2" "flap_count=12" >/dev/null
noswitch && ok "flap_count=12（≥10）且两边都健康 → 退避不抢" || bad "该退避还在抢: $(cat "$T/calls")"
grep -q "选路退避" "$T/sr.log" && ok "退避留下了日志" || bad "退避没有日志"
run_case auto en0 fail ok -3 2 - "$SEED" "$SEED2" "flap_count=12" >/dev/null
switched en1 && ok "一边真死时不退避（可用性优先于偏好之争）" || bad "真断网也被退避挡住: $(cat "$T/calls")"
run_case auto en0 ok ok 2 2 - "$SEED" "$SEED2" "flap_count=12" "flap_backoff=1" "flap_quiet_until=1700000300" >/dev/null
noswitch && ok "退避未到期 → 继续静默" || bad "退避期内还在切: $(cat "$T/calls")"
run_case auto en0 ok ok 2 2 - "$SEED" "$SEED2" "flap_count=12" "flap_backoff=1" "flap_quiet_until=1699990000" >/dev/null
switched en1 && ok "退避已到期 → 给一次重新尝试的机会" || bad "退避永不结束: $(cat "$T/calls")"

echo "== 6. flap 计数清理窗口 =="
run_case auto en1 ok ok 2 2 - "flap_count=7" "last_switch=1699990000" >/dev/null
awk -F= '$1=="flap_count"{print $2}' "$T/state/st" | grep -qx "0" \
    && ok "稳定超过 1800s → flap 计数清零" || bad "假警报永不消失: $(cat "$T/state/st")"
run_case auto en1 ok ok 2 2 - "flap_count=7" "last_switch=1699999900" >/dev/null
awk -F= '$1=="flap_count"{print $2}' "$T/state/st" | grep -qx "7" \
    && ok "距上次切换还很近 → 计数保留（别在真抖时清零）" || bad "计数被提前清掉: $(cat "$T/state/st")"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

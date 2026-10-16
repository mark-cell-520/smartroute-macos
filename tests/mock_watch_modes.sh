#!/bin/bash
# 测试 cmd_watch 的四种 MODE 分支 + 冷却期 + VPN 护栏
#
# 为什么必须测：cmd_watch 是守护进程每 20 秒跑的那一个函数，用户看到的
# 所有自动选路行为都在这里发生。已有的 mock_watch_integration 覆盖的是
# pf / 安全阀 / 静态路由，**MODE 的四个分支（ethernet/wifi/speed/latency）
# 和冷却期完全没有覆盖**——而这正是"选路策略"本身。
#
# 方法：source 之后重定义 find_active / probe_dev / do_switch / default_dev，
# 只验 cmd_watch 自己的决策。比 mock networksetup/ifconfig/route 更直接，
# 也不会因为 mock 输出格式不对而测到别的东西去。
#
# 运行: bash tests/mock_watch_modes.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_wmodes.XXXXXX)"
mkdir -p "$T/bin" "$T/state"
trap 'rm -rf "$T"' EXIT
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"

# date +%s 固定返回，冷却期断言才可控
cat > "$T/bin/date" <<'EOF'
#!/bin/bash
[ "${1:-}" = "+%s" ] && { echo "${MOCK_NOW:-1700000000}"; exit 0; }
exec /bin/date "$@"
EOF
chmod +x "$T/bin/date"
cat > "$T/bin/pfctl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/pfctl"

# 子 shell 的公共前缀。注意：函数体里一律用 echo 而不是 printf '%s\n'——
# 这段文本要经 "bash -c "$common ..."" 一层，单引号格式串里的反斜杠
# 会被吃掉，default_dev 会返回 "en1n" 而不是 "en1"，VPN 判断跟着全错。
# （双引号的 printf "%s\n" 不受影响，只有单引号版会中招。）
common='
    . "'$T'/sr.sh"
    trap - EXIT INT TERM HUP
    export PATH="'$T'/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export LOG_FILE="'$T'/sr.log" STATE_FILE="'$T'/state/st" MOCK_CALLS="'$T'/calls"
    export STATE_WRITABLE=1 LOCK_DIR="'$T'/lock"
    export NOTIFY=0 AUTO_WIFI_POWER=0 BALANCE=0 WIFI_FAILOVER=0
    find_active() { ACTIVE_ETH_DEV=en0; ACTIVE_WIFI_DEV=en1
                    ACTIVE_ETH_SVC="Ethernet"; ACTIVE_WIFI_SVC="Wi-Fi"; }
    probe_dev() { case "$1" in
                      en0) printf "%s\n" "$MOCK_ETH_RES" ;;
                      en1) printf "%s\n" "$MOCK_WIFI_RES" ;;
                  esac; }
    do_switch() { printf "SWITCH %s\n" "$1" >> "$MOCK_CALLS"; }
    default_dev() { echo "${MOCK_DEFAULT_DEV:-en1}"; }
    apply_rules() { :; }
    wifi_failover_if_needed() { :; }
'

# 跑一次 watch。环境变量（MOCK_ETH_RES / MOCK_WIFI_RES / MOCK_DEFAULT_DEV /
# MOCK_ETH_STREAK / MOCK_WIFI_STREAK）由调用方在**父 shell** export，
# 因为 run_watch 是在父 shell 里读 streak 来 seed state 的。
run_watch() {
    : > "$T/calls"; : > "$T/sr.log"; : > "$T/state/st"
    # seed 滞回 streak：cmd_watch 的可用性判定要连续 OK_N(=2) 次成功才判"可用"，
    # 单次跑 watch 只把 streak 推到 1，两个接口都会落到 ok=0、want 恒空。
    # 预置 streak 就是模拟"已经确认过可用"的稳态。
    printf 'streak_eth=%s\nstreak_wifi=%s\n' \
        "${MOCK_ETH_STREAK:-2}" "${MOCK_WIFI_STREAK:-2}" > "$T/state/st"
    bash -c "$common
        MODE='$1'
        # 默认值必须在子 shell 里补：父 shell 没 export 时子 shell 读到空，
        # probe_dev 会返回空串，update_streak 按“无法识别”处理 -> streak 归零，
        # 于是所有用例都判成“不可用”、want 恒空。看起来像选路逻辑坏了，
        # 其实是探测替身没拿到值。
        export MOCK_ETH_RES="${MOCK_ETH_RES:-ok}" MOCK_WIFI_RES="${MOCK_WIFI_RES:-ok}"
        ${2:-}
        cmd_watch
    " 2>&1
}
run_watch_out() { run_watch "$@"; }

echo "== 1. MODE=ethernet：只看以太网 =="
export MOCK_DEFAULT_DEV=en1      # 当前走 Wi-Fi，切到以太网才算一次切换
run_watch ethernet
grep -q "SWITCH en0" "$T/calls" && ok "以太网可用时选 en0" || bad "没选 en0: $(cat "$T/calls")"
MOCK_WIFI_RES=fail MOCK_WIFI_STREAK=-3 run_watch ethernet
grep -q "SWITCH en0" "$T/calls" && ok "Wi-Fi 失败也不影响 ethernet 模式" || bad "Wi-Fi 失败时行为不对"
MOCK_WIFI_STREAK=2; unset MOCK_WIFI_RES

echo "== 2. MODE=wifi：只看 Wi-Fi =="
export MOCK_DEFAULT_DEV=en0      # 当前走以太网，切到 Wi-Fi 才算一次切换
run_watch wifi
grep -q "SWITCH en1" "$T/calls" && ok "Wi-Fi 可用时选 en1" || bad "没选 en1"
MOCK_ETH_RES=fail MOCK_ETH_STREAK=-3 run_watch wifi
grep -q "SWITCH en1" "$T/calls" && ok "以太网失败也不影响 wifi 模式" || bad "以太网失败时行为不对"
MOCK_ETH_STREAK=2; unset MOCK_ETH_RES

echo "== 3. MODE=auto（默认）：以太网优先 =="
export MOCK_DEFAULT_DEV=en1
run_watch auto
grep -q "SWITCH en0" "$T/calls" && ok "两个都可用时优先以太网" || bad "没优先以太网: $(cat "$T/calls")"
MOCK_ETH_RES=fail MOCK_ETH_STREAK=-3 MOCK_DEFAULT_DEV=en0 run_watch auto
grep -q "SWITCH en1" "$T/calls" && ok "以太网失败时退到 Wi-Fi" || bad "没退到 Wi-Fi: $(cat "$T/calls")"
MOCK_ETH_STREAK=2; unset MOCK_ETH_RES

echo "== 4. MODE=speed：网速优先 =="
export MOCK_DEFAULT_DEV=en1
run_watch speed
grep -q "SWITCH" "$T/calls" && bad "没测出吞吐就切换了" || ok "没测出数据时保持现状（不瞎猜）"
# 指标缓存的格式是 "值 时间戳"，时间戳贴近 MOCK_NOW 才算是新鲜的，
# 否则 ensure_throughput/ensure_latency 会**真去测量**——测试就跑到真实网络上，
# 结果随机器而变，还慢。
# 两个坑：
#  1) 必须在 run_watch 的 $2 槽位里写。run_watch 会先清空 state 再 seed streak，
#     在外面先写会被抹掉。（最早就是在外面写的，两条用例其实在真测延迟。）
#  2) 用 echo 而不是 printf "...\n"：这段代码文本要再经一层 bash -c，
#     里面的反斜杠不稳。echo 一条一行，没有任何转义。
metric_code() {   # $1=eth键 $2=eth值 $3=wifi键 $4=wifi值 -> 一段可执行的 shell 代码
    printf 'echo "%s=%s 1700000000" >> "$STATE_FILE"; echo "%s=%s 1700000000" >> "$STATE_FILE"' \
        "$1" "$2" "$3" "$4"
}
run_watch speed "$(metric_code speed_en0 12000000 speed_en1 4000000)"
grep -q "SWITCH en0" "$T/calls" && ok "以太网更快时选 en0" || bad "没选更快的: $(cat "$T/calls")"
MOCK_DEFAULT_DEV=en0 run_watch speed "$(metric_code speed_en0 4000000 speed_en1 12000000)"
grep -q "SWITCH en1" "$T/calls" && ok "Wi-Fi 更快时选 en1" || bad "没选更快的: $(cat "$T/calls")"

echo "== 5. MODE=latency：延时优先 =="
export MOCK_DEFAULT_DEV=en1
run_watch latency
grep -q "SWITCH" "$T/calls" && bad "没测出延迟就切换了" || ok "没测出数据时保持现状"
run_watch latency "$(metric_code lat_en0 12 lat_en1 40)"
grep -q "SWITCH en0" "$T/calls" && ok "以太网延迟低时选 en0" || bad "没选延迟低的: $(cat "$T/calls")"
MOCK_DEFAULT_DEV=en0 run_watch latency "$(metric_code lat_en0 40 lat_en1 12)"
grep -q "SWITCH en1" "$T/calls" && ok "Wi-Fi 延迟低时选 en1" || bad "没选延迟低的: $(cat "$T/calls")"

echo "== 6. 冷却期：防止在两个接口间反复横跳 =="
export MOCK_DEFAULT_DEV=en0
export MOCK_ETH_RES=fail MOCK_ETH_STREAK=-3
run_watch auto 'printf "last_switch=1700000000\n" >> "'$T'/state/st"'
[ -s "$T/calls" ] && bad "冷却期内还切换" || ok "冷却期内跳过切换"
COOLDOWN=45 run_watch auto 'printf "last_switch=1699999900\n" >> "'$T'/state/st"'
grep -q "SWITCH en1" "$T/calls" && ok "超过冷却期后允许切换" || bad "超过冷却期还不让切换"
run_watch auto 'printf "last_switch=garbage\n" >> "'$T'/state/st"'
grep -q "SWITCH en1" "$T/calls" && ok "last_switch 非数字时不误入冷却" || bad "脏数据被当成刚切换过，导致永远不切换"
unset MOCK_ETH_RES; MOCK_ETH_STREAK=2; unset MOCK_ETH_STREAK

echo "== 7. 默认路由被 VPN 持有时不干预 =="
export MOCK_DEFAULT_DEV=utun4
out="$(run_watch_out ethernet)"
[ -s "$T/calls" ] && bad "VPN 持有默认路由时还切换" || ok "VPN 持有时不干预"
printf '%s' "$out" | grep -q "由 VPN/其他接口持有" \
    && ok "留下了可查的提示（用户能看到为什么不干预）" || bad "没记录为什么不干预"
unset MOCK_DEFAULT_DEV

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

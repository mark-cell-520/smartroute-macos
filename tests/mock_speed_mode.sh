#!/bin/bash
# 测试「网速优先 / 延时优先」选路模式
#
# 背景：MODE=auto 只看"哪个能上网"，有线永远赢。但链路质量可以差很多——
# 本例网线只协商到 100baseTX，Wi-Fi 标称 1000M。所以新增两个按实测质量选路的模式。
#
# 为什么必须 mock：measure_throughput 会真的用 curl 下载数据（费流量、耗时数秒），
# 在测试里跑会把机器流量打满、还拖慢整个回归。这里把 curl/ping 换成假件。
#
# 重点验证：
#   1. Wi-Fi 读不到链路速率（networksetup -getMedia 只回 autoselect），
#      所以必须走实测，不能看标称值
#   2. 差距不到阈值要判 tie（否则两条差不多的线路之间会来回横跳）
#   3. 一方测不出来 / 双方都测不出来时的兜底
#   4. 缓存过期判定：测速结果不能每个周期重测
#
# 运行: bash tests/mock_speed_mode.sh
cd "$(dirname "$0")/.."
SRC=smartroute.sh
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d /tmp/sr_speed.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run" "$T/etc"

# ---------- 假 curl：按接口返回不同的"下载速度" ----------
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
# 取 --interface 后面的设备名，返回 MOCK_SPEED_<dev>
dev=""
while [ $# -gt 0 ]; do
    # 注意：不能用 `[ ... ] && { ...; continue }`——macOS 的 bash 3.2
    # 不接受 continue 出现在 AND 列表里，会报 syntax error near 'done'
    if [ "$1" = "--interface" ]; then dev="$2"; shift 2; else shift; fi
done
eval "v=\${MOCK_SPEED_$dev:-0}"
echo -n "$v"
exit 0
EOF

# ---------- 假 ping：按接口返回不同的延迟 ----------
cat > "$T/bin/ping" <<'EOF'
#!/bin/bash
dev=""
# ping 的目标在最后；我们用 MOCK_LAT_<dev> 决定，这里靠路由表文件判断接口
for a in "$@"; do case "$a" in -*) ;; *) tgt="$a" ;; esac; done
for d in en0 en1; do
    grep -q " $tgt $d " "$MOCK_ROUTES" 2>/dev/null && dev="$d"
done
eval "v=\${MOCK_LAT_$dev:-0}"
# 输出成 ping 的 round-trip 行：min/avg/max/stddev
awk -v v="$v" 'BEGIN{ printf "round-trip min/avg/max/stddev = %s/%s/%s/%s ms\n", v, v, v, v }'
exit 0
EOF
# dev_active 靠 ifconfig 判断接口有没有 IP；不接管的话它会去问真 ifconfig，
# 结果取决于真机状态，测试就漂了
cat > "$T/bin/ifconfig" <<'EOF'
#!/bin/bash
case "$1" in
    en0|en1)
        if [ "${MOCK_IF_UP:-1}" = "1" ]; then
            echo "$1: flags=8863<UP> mtu 1500"
            echo -e "\tinet 192.168.1.5 netmask 0xffffff00"
        fi
        exit 0 ;;
esac
exec /sbin/ifconfig "$@"
EOF
chmod +x "$T/bin/"*

sed -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/run/state\"|" \
    -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/run/log\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/lock\"|" \
    -e "s|^USER_CONF=.*|USER_CONF=\"$T/etc/user.conf\"|" \
    -e "s|^CONF=.*|CONF=\"$T/etc/smartroute.conf\"|" \
    -e "s|^RULES_FILE=.*|RULES_FILE=\"$T/etc/smartroute.rules\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"

run() {
    bash -c "
        export PATH='$T/bin:$PATH'
        export MOCK_ROUTES='$T/routes'
        export MOCK_SPEED_en0='${MOCK_SPEED_en0:-0}' MOCK_SPEED_en1='${MOCK_SPEED_en1:-0}'
        export MOCK_LAT_en0='${MOCK_LAT_en0:-0}' MOCK_LAT_en1='${MOCK_LAT_en1:-0}'
        export MOCK_TIMELINE='${MOCK_TIMELINE:-}' 
        . '$T/sr.sh'
        ACTIVE_ETH_DEV=en0; ACTIVE_WIFI_DEV=en1
        ACTIVE_ETH_SVC=Ethernet; ACTIVE_WIFI_SVC='Wi-Fi'
        $1
    " 2>&1
}

echo "=== 1. 链路速率：以太网读得到，Wi-Fi 读不到 ==="
# 这是整个设计的前提：Wi-Fi 没有可读的协商速率，所以"网速优先"只能靠实测
cat > "$T/bin/networksetup" <<'EOF'
#!/bin/bash
case "$1" in
    -getMedia)
        if [ "$2" = "en0" ]; then
            echo "Current: autoselect"; echo "Active: 100baseTX <full-duplex flow-control>"
        else
            echo "Current: autoselect"; echo "Active: autoselect"
        fi
        exit 0 ;;
    # find_active 要靠这两项才能找到 en0/en1，不实现的话 ACTIVE_*_DEV 全是空，
    # 后面所有 speed_<dev> 的 key 都会变成 speed_（没有设备名），测试全部失真
    -listallhardwareports)
        printf 'Hardware Port: Wi-Fi\nDevice: en1\nEthernet Address: aa:bb\n\n'
        printf 'Hardware Port: Ethernet\nDevice: en0\nEthernet Address: cc:dd\n\n'
        exit 0 ;;
    -listnetworkserviceorder)
        printf '(1) Wi-Fi\n\t(Hardware Port: Wi-Fi, Device: en1)\n\n'
        printf '(2) Ethernet\n\t(Hardware Port: Ethernet, Device: en0)\n\n'
        exit 0 ;;
    -getairportpower) echo "Wi-Fi Power (en1): On"; exit 0 ;;
    -getinfo) echo "Router: 192.168.1.1"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/bin/networksetup"
out="$(run 'link_media en0')"
[ "$out" = "100baseTX <full-duplex flow-control>" ] && ok "以太网读到 100baseTX：$out" || bad "得到: $out"
out="$(run 'link_media en1')"
[ "$out" = "autoselect" ] && ok "Wi-Fi 只回 autoselect（读不到速率，印证必须实测）" || bad "得到: $out"

echo "=== 2. fmt_bps 换算 ==="
for pair in "0:未知" "1338605:10.7 Mbps" "1993576:15.9 Mbps" "12500000:100 Mbps"; do
    in="${pair%%:*}"; want="${pair##*:}"
    got="$(run "fmt_bps $in")"
    [ "$got" = "$want" ] && ok "$in B/s → $got" || bad "$in 期望 ${want}，得到 $got"
done

echo "=== 3. measure_throughput 按接口分别测 ==="
export MOCK_SPEED_en0=1993576 MOCK_SPEED_en1=1338605
out="$(run 'measure_throughput en0 5')"
[ "$out" = "1993576" ] && ok "en0 测到 1993576 B/s" || bad "得到: $out"
out="$(run 'measure_throughput en1 5')"
[ "$out" = "1338605" ] && ok "en1 测到 1338605 B/s" || bad "得到: $out"
# 测不到（返回 0）时必须判失败，不能把 0 当成"测出来是 0"
export MOCK_SPEED_en0=0
out="$(run 'measure_throughput en0 5; echo rc=$?')"
printf '%s' "$out" | grep -q "rc=1" && ok "curl 返回 0 时判失败（不是真有 0 速度）" || bad "应失败: $out"
export MOCK_SPEED_en0=1993576

echo "=== 4. pick_by_speed：大的赢，差距小判 tie ==="
out="$(run 'pick_by_speed en0 1993576 en1 1338605')"
[ "$out" = "en0" ] && ok "15.9 vs 10.7 Mbps（差 49%）→ en0" || bad "得到: $out"
out="$(run 'pick_by_speed en0 1000000 en1 1100000')"
[ "$out" = "tie" ] && ok "差 10% < 30% 阈值 → tie（不折腾）" || bad "得到: $out"
out="$(run 'pick_by_speed en0 1000000 en1 1400000')"
[ "$out" = "en1" ] && ok "差 40% > 30% → en1" || bad "得到: $out"
out="$(run 'pick_by_speed en0 0 en1 1100000')"
[ "$out" = "en1" ] && ok "只有一边测到 → 直接用那边" || bad "得到: $out"
out="$(run 'pick_by_speed en0 0 en1 0')"
[ -z "$out" ] && ok "两边都没测到 → 空（保持现状）" || bad "应输出空，得到: $out"

echo "=== 5. 缓存：测速结果不能每周期重测 ==="
out="$(run '_metric_set speed_en0 1993576; _metric_fresh speed_en0 300 && echo fresh || echo stale')"
[ "$out" = "fresh" ] && ok "刚测的 300 秒内算新鲜" || bad "得到: $out"
out="$(run '_metric_set speed_en0 1993576; _metric_fresh speed_en0 0 && echo fresh || echo stale')"
[ "$out" = "stale" ] && ok "有效期 0 秒立刻过期" || bad "得到: $out"
out="$(run '_metric_fresh speed_nonexistent 300 && echo fresh || echo stale')"
[ "$out" = "stale" ] && ok "没有记录时算过期（会触发首次测量）" || bad "得到: $out"

echo "=== 6. ensure_throughput：只测陈旧的，新鲜的跳过 ==="
# state 文件在外层直接准备：en0 刚测过（新鲜），en1 是很久以前测的（过期）。
# 不能把这些操作塞进 run 的 $1——run() 用双引号包裹，$1 里的 \$VAR 不会被二次展开。
rm -f "$T/run/state"
printf 'speed_en0=1993576 %s\n' "$(date +%s)" > "$T/run/state"
printf 'speed_en1=888888 1\n'                  >> "$T/run/state"
out="$(run 'SPEED_RECHECK=300
    ensure_throughput en0 en1
    echo "en0=$(_metric_val speed_en0) en1=$(_metric_val speed_en1)"')"
printf '%s' "$out" | grep -q "en0=1993576" && ok "新鲜的不重测（省流量）" || bad "重测了新鲜的: $out"
printf '%s' "$out" | grep -q "en1=1338605" && ok "过期的重测了（旧值 888888 被换掉）" || bad "没重测过期的: $out"

echo "=== 7. 串行测量（并行会互相抢带宽，两个数都变小）==="
# 行为验证，不再 grep 源码找 "&"：
# 静态检查只能证明"现在没有 &"，证明不了测量真的不重叠——将来换成
# DispatchQueue.concurrentPerform 之类没有 & 的并行写法，它照样通过，
# 而带宽互相抢的问题已经发生了。
# 现在让 measure_throughput 记录"开始/结束"时间线，断言第二次测量
# 必须发生在第一次结束之后（严格不重叠）。
: > "$T/timeline"
out="$(MOCK_TIMELINE="$T/timeline" run '
    SPEED_RECHECK=0                 # 强制当过期：前面几节留下的新鲜缓存会让它跳过测量
    measure_throughput() {
        echo "start $1 $(date +%s%N)" >> "$MOCK_TIMELINE"
        sleep 0.2                      # 模拟一次测量要花点时间
        echo "end   $1 $(date +%s%N)" >> "$MOCK_TIMELINE"
        echo 1000000
    }
    ensure_throughput en0 en1
    cat "$MOCK_TIMELINE"' 2>&1)"
n_start=$(printf '%s' "$out" | grep -c "^start")
n_end=$(printf '%s' "$out" | grep -c "^end")
[ "$n_start" = "2" ] && [ "$n_end" = "2" ] && ok "两个接口都测了" || bad "测量次数不对: $out"
# 用顺序而不是时间戳：macOS 的 date 不支持 %N，拿不到亚秒时间。
# 而顺序已经足够——串行时时间线必然是
#   start en0 → end en0 → start en1 → end en1
# 一旦并行就会交错成 start en0 → start en1 → ...，一眼看出来。
seq="$(printf '%s' "$out" | awk '/^(start|end)/{print $1, $2}' | tr '\n' ',')"
if [ "$seq" = "start en0,end en0,start en1,end en1," ]; then
    ok "严格串行：第二次测量在第一次结束之后才开始（没有重叠）"
else
    bad "测量重叠了（并行测速会互相抢带宽）: $seq"
fi
first=$(printf '%s' "$out" | awk '/^start/{print $2; exit}')
[ "$first" = "en0" ] && ok "先测 eth 再测 wifi（顺序可预期）" || bad "测量顺序变了: $first"

echo "=== 8. 测速失败不覆盖旧值 ==="
out="$(run 'SPEED_RECHECK=0 MOCK_SPEED_en0=0
    _metric_set speed_en0 1993576      # 先有个旧值
    ensure_throughput en0
    echo "val=$(_metric_val speed_en0)"')"
printf '%s' "$out" | grep -q "val=1993576" && ok "测速失败时保留旧值（旧值至少是参考）" || bad "旧值被清掉了: $out"

echo "=== 9. 新模式通过 MODE 校验 ==="
out="$(bash smartroute.sh set bogus 2>&1 | head -1)"
printf '%s' "$out" | grep -q "无法识别\|MODE 只能" && ok "非法模式仍被拒绝" || bad "非法模式没被拒: $out"
for m in auto ethernet wifi speed latency; do
    out="$(bash -c ". '$T/sr.sh'; cmd_set $m" 2>&1 | head -1)"
    printf '%s' "$out" | grep -q "已设置 MODE=$m" && ok "MODE=$m 可用" || bad "MODE=$m 被拒: $out"
done

echo "=== 10. measurements 输出 App 能解析 ==="
out="$(run '_metric_set speed_en0 1993576; _metric_set speed_en1 1338605
    _metric_set lat_en0 14.6; _metric_set lat_en1 14.4
    cmd_measurements')"
printf '%s' "$out" | grep -q "speed:eth=15.9 Mbps" && ok "speed:eth 格式正确" || bad "格式错: $out"
printf '%s' "$out" | grep -q "latency:wifi=14.4 ms" && ok "latency:wifi 格式正确" || bad "格式错: $out"
# 清空 state 再测：否则上一个 run 写进去的实测结果还在，永远测不到"未测"分支
rm -f "$T/run/state"
out="$(run 'cmd_measurements')"
printf '%s' "$out" | grep -q "speed:eth=未测" && ok "没测过显示未测（不是空白）" || bad "空白: $out"
printf '%s' "$out" | grep -q "latency:eth=未测" && ok "延迟没测也显示未测" || bad "空白: $out"

echo
echo "== 11. 0 和负数必须当「没测到」，不能当合法值 =="
# 出过真 bug：cmd_measure 用 state_set lat_$dev 0 作废缓存，测失败不覆写，
# 于是 state 里留着 "0"。pick_fastest 只查空串，0ms 永远赢——
# latency 模式会钉死在那个其实很慢（甚至已死）的接口上。
# pick_by_speed 早就处理了 <=0，两边不一致。
_pf() {   # pick_fastest 的判定
    bash -c "
        . '$T/sr.sh'
        pick_fastest $1
    " 2>/dev/null
}
_ps() {   # pick_by_speed 的判定
    bash -c "
        . '$T/sr.sh'
        pick_by_speed $1
    " 2>/dev/null
}
[ "$(_pf 'en0 0 en1 12')" = "en1" ] && ok "pick_fastest: 0 不当合法延迟（B 赢）" || bad "pick_fastest 0 被当合法: $(_pf 'en0 0 en1 12')"
[ "$(_pf 'en0 12 en1 0')" = "en0" ] && ok "pick_fastest: 0 在 B 侧时 A 赢" || bad "B 侧 0 处理错: $(_pf 'en0 12 en1 0')"
[ -z "$(_pf 'en0 0 en1 0')" ] && ok "pick_fastest: 两边都是 0 时判"没测到"" || bad "两边 0 却有结论"
[ "$(_pf 'en0 -5 en1 12')" = "en1" ] && ok "pick_fastest: 负延迟被拒" || bad "负延迟被当合法"
[ "$(_pf 'en0 12.5 en1 10')" = "en1" ] && ok "pick_fastest: 小数正常比较" || bad "小数比较错"
# 和 pick_by_speed 对齐：同为 <=0 都当没测到
[ "$(_ps 'en0 0 en1 1100000')" = "en1" ] && ok "pick_by_speed: 0 不当合法吞吐" || bad "pick_by_speed 0 被当合法"
# tie 阈值两边要一致（以前 speed 用 <、latency 用 <=，同一差距一个换一个不换）
[ "$(_pf 'en0 10 en1 12')" = "en0" ] && ok "正好 20% 差距时判赢家（与 speed 一致）" || bad "阈值不一致: $(_pf 'en0 10 en1 12')"
[ "$(_pf 'en0 10 en1 11')" = "tie" ] && ok "不到 20% 判平手" || bad "平手判断错: $(_pf 'en0 10 en1 11')"

# _metric_val 也不能把 0 透传出去（否则界面显示"0 ms"误导用户）。
# 用临时脚本文件而不是内联 bash -c：嵌套引号在 bash 里很容易写错，
# 而且错了报的是外层脚本的行号，很难查。
cat > "$T/mv.sh" <<'MVEOF'
#!/bin/bash
T="$1"; v="$2"
. "$T/sr.sh"
STATE_FILE="$T/st"; STATE_WRITABLE=1
state_set lat_x "$v"
printf '%s' "$(_metric_val lat_x)"
MVEOF
_mv() { bash "$T/mv.sh" "$T" "$1" 2>/dev/null; }
[ "$(_mv 12.5)" = "12.5" ] && ok "_metric_val: 正常值透传" || bad "正常值被滤掉"
[ -z "$(_mv 0)" ]     && ok "_metric_val: 0 当没测到" || bad "0 被透传了"
[ -z "$(_mv 0.0)" ]   && ok "_metric_val: 0.0 当没测到" || bad "0.0 被透传了"
[ -z "$(_mv -5)" ]    && ok "_metric_val: 负数当没测到" || bad "负数被透传了"
[ -z "$(_mv abc)" ]   && ok "_metric_val: 非数字当没测到" || bad "非数字被透传了"
[ "$(_mv 0.001)" = "0.001" ] && ok "_metric_val: 小正数仍透传" || bad "小正数被误滤"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# 测试附近网络扫描与候选排序
#
# 为什么值得单独立测试：这套逻辑的核心难点全在"系统扫描有冷却"上——
# 实测约每 5 秒才肯真扫一次，冷却期内问其它 SSID 会拿上次的缓存回答，
# 于是被误判成"不在范围"。如果把这当成真信号，就会把一个明明能用的网络
# 排到最后甚至跳过。这些边界在正常路径上根本看不出来。
#
# 运行: bash tests/mock_wifi_scan.sh
cd "$(dirname "$0")/.."
SRC="$PWD/smartroute.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d /tmp/sr_wifiscan.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run" "$T/etc"

# ---------- mock：wifiscan helper ----------
# 行为由 MOCK_SCAN_OUT 控制（TSV：SSID\trssi\tchannel\tfresh）
cat > "$T/bin/wifiscan" <<'EOF'
#!/bin/bash
for a in "$@"; do [ "$a" = "--quick" ] && continue; done
printf '%b' "${MOCK_SCAN_OUT:-}"
exit ${MOCK_SCAN_RC:-0}
EOF
chmod +x "$T/bin/wifiscan"
# helper 要能被 wifi_scan_bin 找到：放到脚本同目录的临时副本旁边
cp "$SRC" "$T/sr.sh"
sed -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/run/log\"|" \
    -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/run/state\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/lock\"|" \
    -e "s|^USER_CONF=.*|USER_CONF=\"$T/etc/user.conf\"|" \
    -e "s|^CONF=.*|CONF=\"$T/etc/smartroute.conf\"|" \
    -e "s|^RULES_FILE=.*|RULES_FILE=\"$T/etc/smartroute.rules\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/pre.sh"
# helper 与 pre.sh 同目录，wifi_scan_bin 用 BASH_SOURCE 就能找到
cp "$T/bin/wifiscan" "$T/wifiscan"

# 注意：MOCK_CURRENT / MOCK_NO_HELPER 也必须在这里导出。
# 曾经漏了 MOCK_CURRENT，mock 的 --current 输出空，wifi_current_all 于是回退
# 去读真的 system_profiler——断言"碰巧"对上（当时真实噪声正好是 -96），
# 测试因为错误的原因通过。后来真实噪声变成 -97 就失败了。
run() {
    bash -c "
        export PATH='$T/bin:$PATH'
        export MOCK_SCAN_OUT='$MOCK_SCAN_OUT' MOCK_SCAN_RC='${MOCK_SCAN_RC:-0}'
        export MOCK_CURRENT='${MOCK_CURRENT:-}' MOCK_NO_HELPER='${MOCK_NO_HELPER:-0}'
        . '$T/pre.sh'
        ACTIVE_WIFI_DEV=en1; ACTIVE_WIFI_SVC='Wi-Fi'
        STATE_FILE='$T/run/state'
        $1
    " 2>&1
}

echo "=== 1. 正常输出：找到的按信号降序 ==="
MOCK_SCAN_OUT=$'CZ-305\t-70\t6\t1\nCZ-BH-407\t-52\t1\t1\n'
out="$(run 'wifi_scan "CZ-305 CZ-BH-407 mm" 0')"
[ "$out" = $'CZ-BH-407 -52 1\nCZ-305 -70 6' ] && ok "按信号降序，强的在前" || bad "得到: $out"

echo "=== 2. 关键陷阱：fresh=0 的\"没找到\"不能信，也不能缓存 ==="
# 系统冷却：先真扫了 A，紧接着问 B 只用 0.02s 且报空，但 B 其实在范围
MOCK_SCAN_OUT=$'A\t-52\t6\t1\nB\t-\t-\t0\n'
out="$(run 'wifi_scan "A B" 0; echo "unknown=$WIFI_SCAN_UNKNOWN"')"
printf '%s' "$out" | grep -q "unknown=1" && ok "把 B 计为\"未能确认\"，不当成不在范围" || bad "没计数: $out"
printf '%s' "$out" | grep -q "A -52" && ok "A 正常返回" || bad "A 丢了: $out"
# B 的假阴性绝不能被写进缓存，否则 25 秒内都查不到它
if grep -q "wifiscan_B" "$T/run/state" 2>/dev/null; then
    bad "假阴性被缓存了（下次 25 秒内都查不到 B）"
else
    ok "假阴性未写入缓存"
fi
rm -f "$T/run/state"

echo "=== 3. fresh=1 的\"没找到\"是权威的，可以缓存 ==="
MOCK_SCAN_OUT=$'A\t-52\t6\t1\nB\t-\t-\t1\n'
out="$(run 'wifi_scan "A B" 0; echo "unknown=$WIFI_SCAN_UNKNOWN"')"
printf '%s' "$out" | grep -q "unknown=0" && ok "权威的未找到不计入未知" || bad "计数错: $out"
grep -q "wifiscan_B" "$T/run/state" 2>/dev/null && ok "权威的未找到已缓存" || bad "没缓存"
rm -f "$T/run/state"

echo "=== 4. 缓存命中：不重复扫 ==="
MOCK_SCAN_OUT=$'A\t-52\t6\t1\n'
run 'wifi_scan "A" 0' >/dev/null
# 换一个完全不同的输出，如果还返回 A 就说明用了缓存
MOCK_SCAN_OUT=$'B\t-40\t11\t1\n'
out="$(run 'WIFI_SCAN_TTL=25; wifi_scan "A" 0')"
[ "$out" = "A -52 6" ] && ok "TTL 内用缓存，没真扫" || bad "得到: $out"
out="$(run 'WIFI_SCAN_TTL=0; wifi_scan "A" 0')"
[ "$out" = "B -40 11" ] && ok "TTL 过期后重新扫" || bad "得到: $out"
rm -f "$T/run/state"

echo "=== 5. 候选排序：有信号的在前，其余保持原序垫后 ==="
MOCK_SCAN_OUT=$'CZ-BH-407\t-60\t1\t1\n'
out="$(run 'wifi_rank_candidates "CZ-305 CZ-BH-407 mm A9-5G"')"
# CZ-BH-407 有信号排第一；其余按原顺序
[ "$out" = "CZ-BH-407 CZ-305 mm A9-5G " ] && ok "有信号的提前，其余原序" || bad "得到: [$out]"

echo "=== 6. helper 缺失时排序原样返回（不改变语义）==="
out="$(run 'wifi_scan_bin() { return 1; }; wifi_rank_candidates "A B C"')"
[ "$out" = "A B C" ] && ok "helper 缺失时原样返回" || bad "得到: [$out]"
out="$(run 'wifi_scan_bin() { return 1; }; wifi_scan "A B" 0; echo "avail=$WIFI_SCAN_AVAILABLE unknown=$WIFI_SCAN_UNKNOWN"')"
printf '%s' "$out" | grep -q "avail=0" && ok "标记 helper 不可用" || bad "没标记: $out"

echo "=== 7. 多 BSSID：取信号最强的 ==="
MOCK_SCAN_OUT=$'A\t-80\t36\t1\nA\t-45\t149\t1\n'
out="$(run 'wifi_scan "A" 0')"
[ "$out" = "A -45 149" ] && ok "取了最强的 BSSID（-45 而非 -80）" || bad "得到: $out"

echo "=== 8. wifi_current_rate：真实协商速率与噪声底 ==="
out="$(run 'wifi_current_rate')"
case "$out" in
    "") echo "  （本机读不到，跳过）" ;;
    *)  printf '  本机实测: %s\n' "$out"
        rate="${out%% *}"
        case "$rate" in
            ''|*[!0-9]*) bad "速率不是数字: $out" ;;
            *) ok "速率可解析: $rate Mbps" ;;
        esac ;;
esac

echo "=== 9. state 写不进去时不报错（普通用户的常态） ==="
out="$(run 'STATE_FILE=/var/db/smartroute/state; wifi_scan "A B" 0' 2>&1)"
if printf '%s' "$out" | grep -qi "Operation not permitted"; then
    bad "刷了权限错误"
else
    ok "写不了 state 时静默降级"
fi

echo "=== 10. wifi_current_all：快路径与兜底 ==="
# 快路径走 CoreWLAN helper，比 system_profiler 快一个数量级
# （实测 helper 首次 0.3s/之后 0.01s，system_profiler 1.6s）。
# helper 不在时必须回退 system_profiler，功能不能少。
cat > "$T/bin/wifiscan" <<'EOF2'
#!/bin/bash
if [ "$1" = "--current" ]; then
    if [ "${MOCK_NO_HELPER:-0}" = "1" ]; then exit 1; fi
    printf '%b' "${MOCK_CURRENT:-}"
    exit 0
fi
printf '%b' "${MOCK_SCAN_OUT:-}"
exit ${MOCK_SCAN_RC:-0}
EOF2
chmod +x "$T/bin/wifiscan"; cp "$T/bin/wifiscan" "$T/wifiscan"
MOCK_CURRENT=$'-70\t44\t432\t-96\n'
out="$(run 'wifi_current_all')"
[ "$out" = "-70 44 432 -96" ] && ok "快路径：helper 输出四项齐全" || bad "得到: $out"
out="$(run 'wifi_current_all | awk "{print \$1, \$4}"')"
[ "$out" = "-70 -96" ] && ok "rssi 与噪声位置正确" || bad "得到: $out"

echo "=== 11. helper 挂了要回退 system_profiler（数据不能少） ==="
out="$(run 'export MOCK_NO_HELPER=1; wifi_current_all')"
# 回退路径读真 system_profiler；本机连着 Wi-Fi 应该有值
if [ -n "$out" ]; then
    ok "回退成功，仍有数据: $out"
    n="$(printf '%s\n' "$out" | wc -w | tr -d ' ')"
    [ "$n" = "4" ] && ok "四项齐全（rssi 信道 速率 噪声）" || bad "只有 $n 项"
else
    echo "  （本机读不到 system_profiler，跳过）"
fi

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

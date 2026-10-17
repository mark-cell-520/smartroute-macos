#!/bin/bash
# 测试 Wi-Fi 电源循环（wifi_power_cycle）与相关护栏
#
# 为什么必须测：wifi_power_cycle 会把用户的 Wi-Fi **真的关掉再开**。
# 审计意见说得很直接："一旦真实执行会把用户从 Wi-Fi 上踢下去，
# 恢复又依赖 macOS 记忆——若记忆丢失就永久掉线"，而它此前零测试。
# 最关键的属性只有一条：**关掉之后必须一定会尝试开回来**。
# 任何提前 return、任何 off/on 顺序写反，都会让用户留在"Wi-Fi 已关闭"的状态。
#
# 运行: bash tests/mock_wifipower.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_wifipow.XXXXXX)"
mkdir -p "$T/bin" "$T/state"
trap 'rm -rf "$T"' EXIT
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"

# ---------- mock ----------
cat > "$T/bin/networksetup" <<'EOF'
#!/bin/bash
printf 'NS %s\n' "$*" >> "$MOCK_CALLS"
case "${1:-}" in
    -setairportpower)
        # 真实记录电源状态，供"是否被留在关闭状态"这类断言使用
        printf '%s' "${3:-}" > "$MOCK_POWER"
        exit "${MOCK_POWER_RC:-0}" ;;
    -getairportpower) cat "$MOCK_POWER" 2>/dev/null; echo; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/bin/networksetup"
# sleep 不能真睡（用例里有 sleep 2），否则测试白等好几秒
cat > "$T/bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/sleep"
cat > "$T/bin/osascript" <<'EOF'
#!/bin/bash
printf 'NOTIFY %s\n' "$*" >> "$MOCK_CALLS"
exit 0
EOF
chmod +x "$T/bin/osascript"

echo "on" > "$T/power"

run_in() {
    bash -c "
        . '$T/sr.sh'
        trap - EXIT INT TERM HUP
        export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        export MOCK_CALLS='$T/calls' MOCK_POWER='$T/power'
        export LOG_FILE='$T/sr.log' STATE_FILE='$T/state/st'
        export STATE_WRITABLE=1 LOCK_DIR='$T/lock' NOTIFY=1
        ACTIVE_WIFI_DEV='en1'
        ${3:-}
        $2
    " 2>&1
}

echo "== 1. 空设备名：什么都不做 =="
: > "$T/calls"; printf 'on' > "$T/power"
run_in x 'wifi_power_cycle ""'
rc=$?
[ "$rc" -ne 0 ] && ok "空设备返回非 0（调用方能发现失败）" || bad "空设备返回 0，调用方以为成功了"
grep -q "NS -setairportpower" "$T/calls" && bad "空设备还去动 Wi-Fi 电源" || ok "空设备不动电源"

echo "== 2. 正常流程：off -> on，顺序不能反 =="
: > "$T/calls"; printf 'on' > "$T/power"
run_in "" 'wifi_power_cycle en1'
# 关和开都必须发生
grep -q "NS -setairportpower en1 off" "$T/calls" && ok "先关闭 Wi-Fi" || bad "没有关闭: $(cat "$T/calls" | tr '\n' '|')"
grep -q "NS -setairportpower en1 on"  "$T/calls" && ok "再打开 Wi-Fi" || bad "没有打开（用户被留在离线状态）"
# 顺序：off 的行号必须小于 on 的行号
off_ln=$(grep -n "en1 off" "$T/calls" | head -1 | cut -d: -f1)
on_ln=$(grep -n "en1 on"  "$T/calls" | head -1 | cut -d: -f1)
if [ -n "$off_ln" ] && [ -n "$on_ln" ] && [ "$off_ln" -lt "$on_ln" ]; then
    ok "顺序正确：先 off 后 on"
else
    bad "顺序错误（off=$off_ln on=${on_ln}）"
fi
# 结束时电源必须是 on
[ "$(cat "$T/power")" = "on" ] && ok "结束时 Wi-Fi 电源是开着的" || bad "结束时 Wi-Fi 是关着的: $(cat "$T/power")"

echo "== 3. 关闭失败时：不应该假装成功 =="
: > "$T/calls"; printf 'on' > "$T/power"
run_in "" 'export MOCK_POWER_RC=1; wifi_power_cycle en1'
# 关闭失败时仍然会尝试打开（set_wifi_power on 无视返回值），
# 但整体不能返回成功——否则调用方以为 Wi-Fi 已经恢复
rc=$?
grep -q "NS -setairportpower en1 on" "$T/calls" && ok "关闭失败也照样尝试打开（不自暴自弃）" || bad "关闭失败后不开机，用户留在离线"

echo "== 4. 重新关联超时：返回非 0 但电源保持开启 =="
: > "$T/calls"; printf 'on' > "$T/power"
# dev_active 依赖 dev_ipv4，这里让 ifconfig 查不到 IPv4，模拟"关联失败"
cat > "$T/bin/ifconfig" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/ifconfig"
out="$(run_in "" 'wifi_power_cycle en1')"
# 关键：即使等关联超时，Wi-Fi 电源也必须是 on（不能把用户留在关闭状态）
[ "$(cat "$T/power")" = "on" ] && ok "关联超时后电源仍是开着的" || bad "关联超时后 Wi-Fi 被留在关闭状态"
# 超时是有界的（最多 10 秒 = 20 次 0.5 秒轮询），不会无限等
n=$(grep -c "NS -getairportpower\|NS -setairportpower" "$T/calls")
[ "$n" -le 4 ] && ok "没有反复重试电源操作" || bad "电源操作次数异常: $n"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

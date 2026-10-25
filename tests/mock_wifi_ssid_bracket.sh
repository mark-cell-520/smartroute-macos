#!/bin/bash
# 复现脚本（审计用）：SSID 含正则元字符（"["）时，wifi_scan 的缓存写入会把
# 整个 state 文件清空
#
# 链路：wifi_scan -> _metric_set "wifiscan_$ssid" -> state_set "$1"
#       state_set 用 `grep -v "^$1=" "$STATE_FILE"` 删旧行，$1 是从
#       networksetup 输出里原样取来的 SSID。SSID 含 "[" 时 BRE 不合法，
#       /usr/bin/grep 报 rc=2 且 **stdout 一个字节都不输出**，
#       于是 $tmp 是空文件，紧接着 printf + mv 用它覆盖 STATE_FILE
#       —— 除新写的那一行外全丢。
#
# 丢失的东西：streak_eth/streak_wifi（滞 hysterisis）、eth_ok/wifi_ok、
# switch_count 与 flap 退避、wifi_failover_last 冷却、测速/延迟缓存。
#
# 触发入口：smartroute wifi scan / wifi tryall（App 的"扫描"按钮同理）。
# 守护进程自己的自动路径不走扫描，所以只在用户手动扫描时炸。
#
# 运行: bash tests/repro_wifi_ssid_bracket.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

SRC=smartroute.sh
T="$(mktemp -d /tmp/sr_br.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/etc"

cat > "$T/bin/networksetup" <<'EOF'
#!/bin/bash
case "$1" in
    -setairportnetwork)
        printf '%s\n' "$3" >> "$MOCK_STATE/joins"
        grep -qxF "$3" "$MOCK_STATE/join_ok" 2>/dev/null \
            && { echo "$3" > "$MOCK_STATE/current"; exit 0; }
        echo "Could not find network $3."; exit 0 ;;
    -listpreferredwirelessnetworks)
        echo "Preferred networks on en1:"; sed 's/^/\t/' "$MOCK_STATE/saved" ;;
    -getairportpower) echo "Wi-Fi Power (en1): On" ;;
    -getinfo) echo "Router: 192.168.1.1" ;;
    *) exit 0 ;;
esac
EOF
# helper 按 argv 收 SSID 并原样回显（与 tools/wifiscan.swift 的行为一致）
cat > "$T/wifiscan" <<'EOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in --quick|--current) continue ;; esac
    [ -n "$a" ] || continue
    if grep -qxF "$a" "$MOCK_STATE/in_range" 2>/dev/null; then printf '%s\t-62\t44\t1\n' "$a"
    else printf '%s\t-\t-\t1\n' "$a"; fi
done
exit 0
EOF
cat > "$T/bin/ifconfig" <<'EOF'
#!/bin/bash
[ "$1" = "en1" ] && { echo "en1: flags=8863<UP> mtu 1500"; echo "	inet 192.168.1.5 netmask 0xffffff00"; exit 0; }
exec /sbin/ifconfig "$@"
EOF
chmod +x "$T/bin/"* "$T/wifiscan"

export MOCK_STATE="$T/state"
printf 'CZ-305\nA[\n'      > "$MOCK_STATE/saved"
printf 'A[\n'              > "$MOCK_STATE/in_range"     # 这个网络在旁边，有信号
: > "$MOCK_STATE/join_ok"
echo "CZ-305" > "$MOCK_STATE/current"

# 一份"有家底"的 state 文件
cat > "$T/state/state" <<'EOF'
eth_ok=1
wifi_ok=1
streak_eth=3
streak_wifi=-2
switch_count=7
wifi_failover_last=1761000000
speed_en1=98765432 1761000001
lat_en1=12 1761000001
EOF

sed -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log\"|" \
    -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/lock\"|" \
    -e "s|^USER_CONF=.*|USER_CONF=\"$T/etc/user.conf\"|" \
    -e "s|^CONF=.*|CONF=\"$T/etc/system.conf\"|" \
    -e "s|^RULES_FILE=.*|RULES_FILE=\"$T/etc/smartroute.rules\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"
: > "$T/etc/user.conf"; : > "$T/etc/system.conf"

cat > "$T/drv.sh" <<'EOF'
#!/bin/bash
export PATH="$MOCK_BIN:$PATH"
export MOCK_STATE
. "$MOCK_SR"
ACTIVE_WIFI_DEV=en1; ACTIVE_WIFI_SVC='Wi-Fi'
eval "$SR_CODE"
EOF
chmod +x "$T/drv.sh"
run() { MOCK_BIN="$T/bin" MOCK_SR="$T/sr.sh" SR_CODE="$1" bash "$T/drv.sh" 2>&1; }

echo "=== 0. 先确认 /usr/bin/grep 对这个键的行为 ==="
/usr/bin/grep -v '^wifiscan_A[=' "$T/state/state" > "$T/g.out" 2>/dev/null
printf '    rc=%s  stdout 行数=%s（脚本里 grep 的 stderr 被 2>/dev/null 吞掉）\n' \
    "$?" "$(grep -c . "$T/g.out")"

echo
echo "=== 1. 扫描前：state 文件内容 ==="
sed 's/^/    /' "$T/state/state"
before="$(grep -c . "$T/state/state")"

echo
echo "=== 2. 跑一次 wifi_scan（cmd_wifi scan / tryall 内部就是它）==="
out="$(run 'wifi_scan "$(wifi_saved_list | tr "\n" " ")" 1')"
printf '    wifi_scan 输出: %s\n' "$(printf '%s' "$out" | tr '\n' '|')"

echo
echo "=== 3. 扫描后：state 文件内容 ==="
sed 's/^/    /' "$T/state/state"
after="$(grep -c . "$T/state/state")"
printf '    行数: %s -> %s\n' "$before" "$after"
if [ "$after" -lt "$before" ]; then
    bad "state 文件被清掉 $((before-after)) 行：streak_eth/streak_wifi/switch_count/wifi_failover_last/测速缓存全丢"
else
    ok "state 文件完好"
fi
grep -q '^streak_wifi=' "$T/state/state" && ok "滞回记忆还在" || bad "streak_wifi 丢了（防抖动的记忆没了）"
grep -q '^wifi_failover_last=' "$T/state/state" && ok "故障转移冷却还在" || bad "wifi_failover_last 丢了（冷却失效，可能立刻再切一次）"

echo
echo "=== 4. 对照组：SSID 不含元字符时一切正常 ==="
printf 'CZ-305\nA9-5G\n' > "$MOCK_STATE/saved"
printf 'A9-5G\n' > "$MOCK_STATE/in_range"
cat > "$T/state/state" <<'EOF'
eth_ok=1
wifi_ok=1
streak_eth=3
streak_wifi=-2
switch_count=7
EOF
b2="$(grep -c . "$T/state/state")"
out="$(run 'wifi_scan "$(wifi_saved_list | tr "\n" " ")" 1' >/dev/null)"
a2="$(grep -c . "$T/state/state")"
printf '    行数: %s -> %s\n' "$b2" "$a2"
[ "$a2" -ge "$b2" ] && ok "普通 SSID 不会动 state" || bad "普通 SSID 也丢了行"

echo
echo "结果: $PASS 通过, $FAIL 失败"

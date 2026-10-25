#!/bin/bash
# 回归测试（原为审计复现脚本，修复后转为回归）：SSID 含空格时，Wi-Fi 候选链整条被按空格切碎
#
# 结论（待验证）：wifi_saved_list 之后所有消费者都用 `tr '\n' ' '` + for 循环
# 把 SSID 列表当成"空格分隔的单词表"，于是带空格的 SSID（"My Home"、
# "iPhone 热点"、"CMCC-EDU 5G"）被拆成两个候选，真正的网络永远试不到。
#
# 关键：所有 mock 的"集合"都用文件（一行一个）表示，绝不用空格分隔的环境变量——
# 否则 mock 自己先拆了，就证明不了是脚本在拆。
#
# 运行: bash tests/repro_wifi_ssid_space.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

SRC=smartroute.sh
T="$(mktemp -d /tmp/sr_sp.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/etc"

# ---------- 假 networksetup ----------
# 每次 -setairportnetwork 尝试都记到 $MOCK_STATE/joins，用来证明"到底试了谁"
cat > "$T/bin/networksetup" <<'EOF'
#!/bin/bash
case "$1" in
    -setairportnetwork)
        ssid="$3"
        printf '%s\n' "$ssid" >> "$MOCK_STATE/joins"
        grep -qxF "$ssid" "$MOCK_STATE/join_ok" 2>/dev/null \
            && { echo "$ssid" > "$MOCK_STATE/current"; exit 0; }
        echo "Could not find network $ssid."
        exit 0 ;;
    -listpreferredwirelessnetworks)
        echo "Preferred networks on en1:"
        sed 's/^/\t/' "$MOCK_STATE/saved" ;;
    -getairportpower) echo "Wi-Fi Power (en1): On" ;;
    -listallhardwareports)
        echo "Hardware Port: Ethernet"; echo "Device: en0"
        echo; echo "Hardware Port: Wi-Fi"; echo "Device: en1" ;;
    -listnetworkserviceorder)
        echo "(1) Ethernet"; echo "(Hardware Port: Ethernet, Device: en0)"
        echo "(2) Wi-Fi"; echo "(Hardware Port: Wi-Fi, Device: en1)" ;;
    -getinfo)
        echo "Wi-Fi Power (en1): On"
        echo "Router: 192.168.1.1" ;;
    *) exit 0 ;;
esac
EOF

# ---------- 假 wifiscan helper ----------
# 真实 helper 收的是 argv 里一个个独立的 SSID（Swift 侧 CommandLine.arguments），
# 所以带空格的 SSID 只要**完整传进去**是能扫到的。这里按完整字符串比对。
cat > "$T/wifiscan" <<'EOF'
#!/bin/bash
any=0
for a in "$@"; do
    case "$a" in --quick|--current) continue ;; esac
    [ -n "$a" ] || continue
    printf 'HELPER-ARG<%s>\n' "$a" >> "$MOCK_STATE/helper_args"
    if grep -qxF "$a" "$MOCK_STATE/in_range" 2>/dev/null; then
        printf '%s\t-62\t44\t1\n' "$a"; any=1
    else
        printf '%s\t-\t-\t1\n' "$a"
    fi
done
[ "$any" = "1" ] || exit 2
exit 0
EOF

# ---------- 假探测 ----------
cat > "$T/bin/probe_ok" <<'EOF'
#!/bin/bash
cur="$(cat "$MOCK_STATE/current" 2>/dev/null)"
grep -qxF "$cur" "$MOCK_STATE/net_ok" 2>/dev/null && exit 0
exit 1
EOF
for c in ping nc curl; do cp "$T/bin/probe_ok" "$T/bin/$c"; done
cat > "$T/bin/ifconfig" <<'EOF'
#!/bin/bash
[ "$1" = "en1" ] && { echo "en1: flags=8863<UP> mtu 1500"; echo "	inet 192.168.1.5 netmask 0xffffff00"; exit 0; }
exec /sbin/ifconfig "$@"
EOF
cat > "$T/bin/route" <<'EOF'
#!/bin/bash
[ "$1" = "-n" ] && { echo "   interface: en1"; exit 0; }
exit 0
EOF
chmod +x "$T/bin/"* "$T/wifiscan"

export MOCK_STATE="$T/state"
printf 'My Home\nOffice 5G\nCZ-305\n'      > "$MOCK_STATE/saved"
printf 'My Home\nCZ-305\n'                 > "$MOCK_STATE/join_ok"   # 在范围且密码对
printf 'My Home\n'                         > "$MOCK_STATE/net_ok"    # 只有这个真有外网
printf 'My Home\n'                         > "$MOCK_STATE/in_range"
: > "$MOCK_STATE/joins"; : > "$MOCK_STATE/helper_args"
echo "BrokenNet" > "$MOCK_STATE/current"   # 当前连的网络上不了网

sed -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log\"|" \
    -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/lock\"|" \
    -e "s|^USER_CONF=.*|USER_CONF=\"$T/etc/user.conf\"|" \
    -e "s|^CONF=.*|CONF=\"$T/etc/smartroute.conf\"|" \
    -e "s|^RULES_FILE=.*|RULES_FILE=\"$T/etc/smartroute.rules\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"

# 驱动脚本：代码走环境变量，彻底避开嵌套引号
cat > "$T/drv.sh" <<'EOF'
#!/bin/bash
export PATH="$MOCK_BIN:$PATH"
export MOCK_STATE
. "$MOCK_SR"
ACTIVE_WIFI_DEV=en1; ACTIVE_WIFI_SVC='Wi-Fi'
eval "$SR_CODE"
EOF
chmod +x "$T/drv.sh"
export MOCK_BIN="$T/bin" MOCK_SR="$T/sr.sh"
run() { SR_CODE="$1" MOCK_BIN="$T/bin" MOCK_SR="$T/sr.sh" bash "$T/drv.sh" 2>&1; }

echo "=== 1. wifi_saved_list 本身是对的（一行一个 SSID，含空格）==="
out="$(run 'wifi_saved_list | sed "s/^/    |/"')"
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -qx '    |My Home' \
    && ok "已保存列表完整保留 'My Home'" || bad "'My Home' 在列表里就丢了"

echo
echo "=== 2. wifi_preferred_candidates 把 'My Home' 拆成两个候选 ==="
# 必须用 while read 迭代：`for s in $(...)` 自己就会词分割，
# 那样测的根本不是代码，而是测试自己的写法。
out2="$(run 'wifi_preferred_candidates | while IFS= read -r s; do printf "    <%s>\n" "$s"; done')"
printf '%s\n' "$out2"
printf '%s\n' "$out2" | grep -qx '    <My Home>' \
    && ok "候选里有完整的 'My Home'" || bad "候选里没有 'My Home'，只有拆碎的 <My> <Home>"

echo
echo "=== 3. wifi_try_candidates 永远试不到真正的网络 ==="
: > "$MOCK_STATE/joins"; echo "BrokenNet" > "$MOCK_STATE/current"
out="$(run 'wifi_try_candidates "$(wifi_preferred_candidates)" 1; echo "rc=$?"')"
printf '%s\n' "$out" | sed 's/^/    /'
echo "    实际调用过 -setairportnetwork 的 SSID："
sed 's/^/      · /' "$MOCK_STATE/joins"
grep -qx 'My Home' "$MOCK_STATE/joins" \
    && ok "确实试连了 'My Home'" || bad "从没试连 'My Home'——真正能上网的网络被漏掉"
[ "$(cat "$MOCK_STATE/current")" = "My Home" ] \
    && ok "已切到 My Home" || bad "仍停在 $(cat "$MOCK_STATE/current")（有外网的网络没被用上）"

echo
echo "=== 4. wifi scan：正连着 'My Home'，却把它报成不在范围 ==="
echo "My Home" > "$MOCK_STATE/current"; : > "$MOCK_STATE/helper_args"
out="$(run 'wifi_nearby 1')"
printf '%s\n' "$out" | sed 's/^/    /'
echo "    传给 helper 的参数（真实 helper 按 argv 收，能收带空格的）："
sed 's/^/      · /' "$MOCK_STATE/helper_args"
printf '%s\n' "$out" | grep -q '^My Home ' \
    && ok "扫到了 My Home（带空格的 SSID 完整传给 helper）" \
    || bad "正在用的 'My Home' 被报成不在范围（拆成 My/Home 各问一次，都找不到）"
# helper 必须按 argv 收到完整的一整个 SSID，而不是拆成两个参数
grep -qF 'HELPER-ARG<My Home>' "$MOCK_STATE/helper_args" \
    && ok "helper 收到完整的 'My Home'（一个 argv，没被拆成两个）" \
    || bad "helper 收到的是拆开的参数：$(tr '\n' '|' < "$MOCK_STATE/helper_args")"

echo
echo "=== 5. cmd_wifi tryall 的完整输出（用户实际看到的）==="
echo "BrokenNet" > "$MOCK_STATE/current"; : > "$MOCK_STATE/joins"
out="$(run 'cmd_wifi tryall')"
printf '%s\n' "$out" | sed 's/^/    /'
if printf '%s\n' "$out" | grep -q '没有检测到 Wi-Fi 接口'; then
    bad "mock 没喂硬件端口，本节无效"
elif printf '%s\n' "$out" | grep -q '找到可用的网络：My Home'; then
    ok "tryall 切到了 'My Home'（用户看得到成功）"
else
    bad "用户被告知'没找到能上网的网络'，而 My Home 明明能上网"
fi
# 真的发起过 join，且参数是完整的 SSID
grep -qx 'My Home' "$MOCK_STATE/joins" \
    && ok "确实对 'My Home' 发起过 join（一个参数）" \
    || bad "从没试连 'My Home'——真正能上网的网络被漏掉"

echo
echo "=== 6. 对照：同一个带空格的网络，直接 join 是成功的（证明坏的只是列表管道）==="
echo "BrokenNet" > "$MOCK_STATE/current"; : > "$MOCK_STATE/joins"
out="$(run 'wifi_join "My Home"; echo "rc=$? reason=$(wifi_join_reason)"')"
printf '    wifi_join "My Home" -> %s\n' "$out"
out2="$(run 'cmd_wifi join "My Home"')"
printf '    cmd_wifi join "My Home" -> %s\n' "$(printf '%s' "$out2" | head -1)"
printf '%s' "$out" | grep -q 'rc=0' \
    && ok "带空格的 SSID 直接传给 networksetup 完全可用" || bad "直接 join 也失败——那说明是 mock 的问题，不是脚本"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

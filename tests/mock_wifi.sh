#!/bin/bash
# 测试 smartroute wifi 命令组 —— 网络选择与自动故障转移
#
# 为什么必须用 mock：wifi join / tryall 会真的切换 Wi-Fi，
# 在用户机器上跑测试等于把人家正在用的网络踢掉。所以这里把
# networksetup / system_profiler / ping / nc 全部换成假件，在临时目录里跑。
#
# 重点验证：
#   1. networksetup -setairportnetwork 失败也返回 0 → 成败必须解析输出文本
#   2. "连上了但没外网"（门户认证/假连接）必须被识别并继续试下一个
#   3. 已保存列表为空 / 接口不存在时不崩溃
#   4. wifi current 的 dBm→格数换算
#
# 运行: bash tests/mock_wifi.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

SRC=smartroute.sh
T="$(mktemp -d /tmp/sr_wifi.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/etc"

# ---------- 假 networksetup ----------
# 行为由环境变量控制：
#   MOCK_SAVED        已保存网络（换行分隔）
#   MOCK_JOIN_OK      允许连接的 SSID（空格分隔）；其它的返回"Could not find network"且退出码 0
#   MOCK_JOIN_CURRENT 当前连接到的 SSID
cat > "$T/bin/networksetup" <<'EOF'
#!/bin/bash
# MOCK_JOIN_FAIL_TEXT：让指定的 SSID 返回"Failed to join"而不是"Could not find"，
# 用来区分"不在范围"和"找到了但连不上"这两种失败
case "$1" in
    -setairportnetwork)
        ssid="$3"
        for f in $MOCK_JOIN_FAIL_TEXT; do
            [ "$f" = "$ssid" ] && { echo "Failed to join network $ssid."; exit 0; }
        done
        for ok in $MOCK_JOIN_OK; do
            [ "$ok" = "$ssid" ] && { echo "$ssid" > "$MOCK_STATE/current"; exit 0; }
        done
        echo "Could not find network $ssid."
        exit 0
        ;;
    -listpreferredwirelessnetworks)
        echo "Preferred networks on en1:"
        printf '%s\n' $MOCK_SAVED | sed '/^$/d' | sed 's/^/\t/'
        ;;
    -setairportnetwork)
        ssid="$3"
        # 关键：macOS 这里失败也返回 0，所以假件也要这么演
        for ok in $MOCK_JOIN_OK; do
            [ "$ok" = "$ssid" ] && { echo "$ssid" > "$MOCK_STATE/current"; exit 0; }
        done
        echo "Could not find network $ssid."
        exit 0
        ;;
    -getairportpower) echo "Wi-Fi Power (en1): On" ;;
    # svc_router 走这条路拿网关；不实现的话 probe_dev 会以"无网关"直接判 fail
    -getinfo)
        echo "Wi-Fi Power (en1): On"
        echo "Router: ${MOCK_ROUTER:-192.168.1.1}" ;;
    -setairportpower) exit 0 ;;
    *) exit 0 ;;
esac
EOF

# ---------- 假 system_profiler ----------
cat > "$T/bin/system_profiler" <<'EOF'
#!/bin/bash
echo "          Current Network Information:"
echo "            <redacted>:"
echo "              PHY Mode: 802.11ax"
echo "              Channel: ${MOCK_CHANNEL:-44} (5GHz, 160MHz)"
echo "              Signal / Noise: ${MOCK_RSSI:--70} dBm / -91 dBm"
EOF

# ---------- 假探测：只有 MOCK_NET_SSID 对应的网络"能上网" ----------
# probe_dev 会调 ping/nc/curl；让它们全部失败，再由 wifi_try_candidates 的上层判断。
# 这里用一个标记文件模拟"连上后有没有外网"。
cat > "$T/bin/ping"   <<'EOF'
#!/bin/bash
# 当前连的网络在 MOCK_NET_OK 里才算通
cur="$(cat "$MOCK_STATE/current" 2>/dev/null)"
for n in $MOCK_NET_OK; do [ "$n" = "$cur" ] && exit 0; done
exit 1
EOF
cat > "$T/bin/nc"     <<'EOF'
#!/bin/bash
cur="$(cat "$MOCK_STATE/current" 2>/dev/null)"
for n in $MOCK_NET_OK; do [ "$n" = "$cur" ] && exit 0; done
exit 1
EOF
cat > "$T/bin/curl"   <<'EOF'
#!/bin/bash
cur="$(cat "$MOCK_STATE/current" 2>/dev/null)"
for n in $MOCK_NET_OK; do [ "$n" = "$cur" ] && exit 0; done
exit 1
EOF
# ifconfig：让 dev_active 认为接口有 IP（只要 MOCK_IF_UP=1）
cat > "$T/bin/ifconfig" <<'EOF'
#!/bin/bash
# 完全接管 en1：MOCK_IF_UP=0 时模拟"连上了但 DHCP 还没拿到地址"，
# 不能回落去问真 ifconfig（真 en1 有 IP，会让这个场景永远测不出来）
if [ "$1" = "en1" ]; then
    if [ "${MOCK_IF_UP:-1}" = "1" ]; then
        echo "en1: flags=8863<UP> mtu 1500"
        echo -e "\tinet 192.168.1.5 netmask 0xffffff00"
    fi
    exit 0
fi
exec /sbin/ifconfig "$@"
EOF
# route：探测时用
cat > "$T/bin/route" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/"*

export MOCK_STATE="$T/state"
export MOCK_SAVED=$'CZ-305\nm\nCZ-BH-407\nmm'
export MOCK_JOIN_OK="CZ-305 CZ-BH-407 mm"
export MOCK_NET_OK="CZ-BH-407"      # 只有这个真有外网
: > "$MOCK_STATE/current"; echo "m" > "$MOCK_STATE/current"   # 现在连的 m 上不了网
export MOCK_RSSI="-70" MOCK_CHANNEL="44"

# 取整个脚本但砍掉入口（保留 dev_active/log/die/probe_dev 等所有辅助函数），
# 跟其它 mock 测试一个套路
sed -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log\"|" \
    -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/lock\"|" \
    -e "s|^USER_CONF=.*|USER_CONF=\"$T/etc/user.conf\"|" \
    -e "s|^CONF=.*|CONF=\"$T/etc/smartroute.conf\"|" \
    -e "s|^RULES_FILE=.*|RULES_FILE=\"$T/etc/smartroute.rules\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"

run() {
    bash -c "
        export PATH='$T/bin:$PATH'
        export MOCK_STATE='$T/state' MOCK_SAVED='$MOCK_SAVED' MOCK_JOIN_OK='$MOCK_JOIN_OK'
        export MOCK_NET_OK='$MOCK_NET_OK' MOCK_RSSI='$MOCK_RSSI' MOCK_CHANNEL='$MOCK_CHANNEL'
        export MOCK_IF_UP=\${MOCK_IF_UP:-1}
        . '$T/sr.sh'
        ACTIVE_WIFI_DEV=en1; ACTIVE_WIFI_SVC='Wi-Fi'
        $1
    " 2>&1
}

echo "=== 1. wifi list 列已保存网络 ==="
out="$(run 'wifi_saved_list | tr "\n" ","')"
[ "$out" = "CZ-305,m,CZ-BH-407,mm," ] && ok "按系统保存顺序输出：$out" || bad "得到: $out"

echo "=== 2. wifi current：dBm 与格数 ==="
# 必须 mock 掉 wifiscan helper，否则这个测试在断言**活硬件**。
# wifi_scan_bin() 的候选列表第 4 项是真实的 /usr/local/bin/smartroute-wifiscan，
# 开发机上都装着；它返回本机实时信号。曾经的断言写死 "-70 44"——44 正是这台
# 机器的真实信道。信号只要从 -70 漂到 -71 dBm 就失败，全量回归里偶发红一次，
# 而单独跑 5 次全绿，极难复现。
# 在 $T 下放一个假 helper：wifi_scan_bin 用 BASH_SOURCE[0] 定位，
# source $T/sr.sh 时 d=$T，$T/wifiscan 是第一个候选，必然压过真实 helper。
cat > "$T/wifiscan" <<'MOCKHELPER'
#!/bin/bash
[ "${1:-}" = "--current" ] || exit 0
# helper 输出 TSV：rssi \t channel \t rate \t noise
printf '%s\t%s\t%s\t%s\n' "${MOCK_RSSI:--70}" "${MOCK_CHANNEL:-44}" \
                        "${MOCK_RATE:-144}" "${MOCK_NOISE:--98}"
exit 0
MOCKHELPER
chmod +x "$T/wifiscan"
out="$(run 'wifi_current_signal')"
[ "$out" = "-70 44" ] && ok "读出信号与信道：$out" || bad "得到: $out"
# helper 不在时要能回退 system_profiler，不能直接失败
out="$(run 'rm -f "$T/wifiscan"; wifi_current_signal')"
printf '%s' "$out" | grep -qE '^-?[0-9]+ [0-9]+$' \
    && ok "helper 缺失时回退 system_profiler（仍读出信号）" \
    || bad "helper 缺失时没有回退，Wi-Fi 没连上就整个函数失败: $out"
for pair in "-45:4" "-55:4" "-62:3" "-70:2" "-78:2" "-88:1" "x:?"; do
    r="${pair%%:*}"; want="${pair##*:}"
    got="$(run "wifi_bars $r")"
    [ "$got" = "$want" ] && ok "$r dBm → $got 格" || bad "$r dBm 期望 $want 格，得到 $got"
done

echo "=== 3. join：成功与失败都要能分辨（networksetup 失败也返回 0）==="
out="$(run 'wifi_join CZ-BH-407; echo "rc=$?"')"
printf '%s' "$out" | grep -q "rc=0" && ok "已保存且存在的网络 → 成功" || bad "应成功: $out"
out="$(run 'wifi_join NOT_SAVED; echo "rc=$?"')"
printf '%s' "$out" | grep -q "rc=1" && ok "不存在的网络 → 判定失败（没被退出码 0 骗到）" || bad "应失败: $out"

echo "=== 4. tryall：跳过不能上网的，找到第一个能用的 ==="
# 注意：上一节的 wifi_join 把 current 留在了 CZ-BH-407（正好是有外网的那个），
# 不复位的话会触发"已能上网就不动"的护栏，本节就永远测不到东西了。
echo m > "$MOCK_STATE/current"
out="$(run 'wifi_try_candidates "CZ-305 CZ-BH-407 mm" 1')"
[ "$out" = "CZ-BH-407" ] && ok "跳过头两个假连接，返回 $out" || bad "期望 CZ-BH-407，得到: $out"
cur="$(cat "$T/state/current")"
[ "$cur" = "CZ-BH-407" ] && ok "确实切到了 $cur" || bad "当前仍是 $cur"

echo "=== 5. tryall：全都不能上网时返回空 ==="
out="$(run 'wifi_try_candidates "CZ-305 mm" 1')"
[ -z "$out" ] && ok "全失败时输出为空" || bad "应输出空，得到: $out"

echo "=== 6. tryall：连上了但拿不到 IP 也要跳过 ==="
out="$(run 'export MOCK_IF_UP=0; echo m > "$MOCK_STATE/current"; wifi_try_candidates "CZ-305 CZ-BH-407" 1')"
[ -z "$out" ] && ok "接口拿不到 IP 时全部跳过" || bad "应输出空，得到: $out"

echo "=== 7. 已保存列表为空时不崩溃 ==="
out="$(run 'export MOCK_SAVED=""; wifi_try_candidates "" 1; echo "rc=$?"')"
printf '%s' "$out" | grep -q "rc=1" && ok "空列表安全返回失败" || bad "应返回 1: $out"

echo "=== 8. 候选列表尊重传入顺序 ==="
# 第 5/6 节把 current 留在了一个没有外网的状态，但第 7 节空列表测试没动它；
# 这里显式复位，避免受前面章节影响
echo m > "$MOCK_STATE/current"
out="$(run 'wifi_try_candidates "mm CZ-BH-407" 1')"
[ "$out" = "CZ-BH-407" ] && ok "按给定顺序试（mm 先失败）" || bad "得到: $out"

echo "=== 9. 命令分派与用法提示 ==="
out="$(run 'cmd_wifi bogus 2>&1' ; echo "rc=$?")"
printf '%s' "$out" | grep -q "用法: smartroute wifi" && ok "未知子命令给出用法" || bad "没有用法提示: $out"
out="$(bash smartroute.sh --help 2>&1)"
printf '%s' "$out" | grep -q "wifi tryall" && ok "--help 登记了 wifi 子命令" || bad "--help 缺 wifi"
printf '%s' "$out" | grep -q "wifi auto on" && ok "--help 登记了自动转移开关" || bad "--help 缺 wifi auto"

echo "=== 10. 普通用户跑不能往 root 日志刷噪音 ==="
out="$(bash smartroute.sh wifi join "__NOPE__" 2>&1)"
if printf '%s' "$out" | grep -q "Operation not permitted"; then
    bad "终端里出现了写日志失败的噪音"
else
    ok "无权限写日志时安静失败"
fi

echo "=== 11. 故障转移护栏：任何一条不满足都不能动网络 ==="
# 这段是全项目最不能出错的地方：误切会把用户正在用的网络踢掉。
# wifi_failover_if_needed <wifi_ok> <eth_ok> <wifi_res>
# 默认 WIFI_FAILOVER=0，先确认"关着的时候绝不动作"
out="$(run 'echo m > "$MOCK_STATE/current"; WIFI_FAILOVER=0; wifi_failover_if_needed 0 0 fail; echo "cur=$(cat $MOCK_STATE/current)"')"
printf '%s' "$out" | grep -q "cur=m" && ok "WIFI_FAILOVER=0 时不动作" || bad "关着却动了: $out"

# 开着，但 Wi-Fi 明明是好的 → 不动
out="$(run 'echo m > "$MOCK_STATE/current"; WIFI_FAILOVER=1; wifi_failover_if_needed 1 0 fail; echo "cur=$(cat $MOCK_STATE/current)"')"
printf '%s' "$out" | grep -q "cur=m" && ok "Wi-Fi 能上网时不动作" || bad "Wi-Fi 好的时候却动了: $out"

# 开着，Wi-Fi 坏了，但以太网有外网 → 不动（默认路由走以太网，切 Wi-Fi 没意义）
out="$(run 'echo m > "$MOCK_STATE/current"; WIFI_FAILOVER=1; wifi_failover_if_needed 0 1 fail; echo "cur=$(cat $MOCK_STATE/current)"')"
printf '%s' "$out" | grep -q "cur=m" && ok "以太网有外网时不动作" || bad "多余动作: $out"

# 开着，都坏了，但用户强制 MODE=ethernet → 不动
out="$(run 'echo m > "$MOCK_STATE/current"; WIFI_FAILOVER=1; MODE=ethernet; wifi_failover_if_needed 0 0 fail; echo "cur=$(cat $MOCK_STATE/current)"')"
printf '%s' "$out" | grep -q "cur=m" && ok "MODE=ethernet 时不动作" || bad "违反用户强制设置: $out"

# 开着，都坏了，但接口压根没激活（wifi_res=na，Wi-Fi 被关了）→ 不动
out="$(run 'echo m > "$MOCK_STATE/current"; WIFI_FAILOVER=1; wifi_failover_if_needed 0 0 na; echo "cur=$(cat $MOCK_STATE/current)"')"
printf '%s' "$out" | grep -q "cur=m" && ok "Wi-Fi 接口未激活时不动作" || bad "对未激活接口瞎试: $out"

# 非 root → 不动（普通用户不该能改系统网络）
out="$(run 'echo m > "$MOCK_STATE/current"; WIFI_FAILOVER=1; wifi_failover_if_needed 0 0 fail; echo "cur=$(cat $MOCK_STATE/current)"')"
if [ "$(id -u)" -ne 0 ]; then
    printf '%s' "$out" | grep -q "cur=m" && ok "非 root 时不动作" || bad "普通用户也能切网络: $out"
else
    echo "  - 跳过（当前是 root）"
fi

echo "=== 12. 冷却：切完不能马上再试（防止在网络间来回跳）==="
out="$(run 'echo m > "$MOCK_STATE/current"; WIFI_FAILOVER=1; WIFI_FAILOVER_COOLDOWN=9999
    state_set wifi_failover_last "$(date +%s)"
    wifi_failover_if_needed 0 0 fail
    echo "cur=$(cat $MOCK_STATE/current)"')"
printf '%s' "$out" | grep -q "cur=m" && ok "冷却期内不动作" || bad "冷却失效: $out"

echo "=== 13. WIFI_PREFERRED 决定试连顺序 ==="
# 首选放最前：即使 CZ-305 排第一，指定 mm 优先就应该先试 mm
out="$(run 'echo m > "$MOCK_STATE/current"; WIFI_FAILOVER=1; WIFI_FAILOVER_COOLDOWN=0
    WIFI_PREFERRED="CZ-BH-407,mm"; echo "cands=[$(wifi_preferred_candidates)]"')"
[ "$out" = "cands=[CZ-BH-407 mm CZ-305 m]" ] && ok "首选靠前且去重：$out" || bad "得到: $out"
out="$(run 'WIFI_PREFERRED=""; echo "cands=[$(wifi_preferred_candidates)]"')"
[ "$out" = "cands=[CZ-305 m CZ-BH-407 mm]" ] && ok "留空=按系统保存顺序：$out" || bad "得到: $out"
# 首选里出现没保存过的名字，不能因此挡住后面的
out="$(run 'WIFI_PREFERRED="GHOST,CZ-305"; echo "cands=[$(wifi_preferred_candidates)]"')"
[ "$out" = "cands=[GHOST CZ-305 m CZ-BH-407 mm]" ] && ok "保留未保存的首选名（让 join 去失败）: $out" || bad "得到: $out"

echo "=== 14. tryall 护栏：当前 Wi-Fi 已能上网时绝不切换（用户实测踩到的坑）==="
# 真实 case：当前 Wi-Fi 有网，tryall 却把当前网络重新 join 了一遍，
# 结果 "Failed to join network CZ-305" —— 自己把一条好线路踢掉了，
# 最后还报"已保存的 Wi-Fi 都没有外网"，完全误导。
# 当前 SSID 读不到（要位置权限），所以没法"跳过当前网络"；
# 但"已经能上网就不动手"不需要知道 SSID。
echo m > "$MOCK_STATE/current"
export MOCK_NET_OK="m"        # 当前网络有外网
out="$(run 'wifi_current_ok && echo OK || echo NO')"
[ "$out" = "OK" ] && ok "wifi_current_ok 认出当前网络能上网" || bad "得到: $out"
# wifi_try_candidates 必须直接放弃，且一个网络都不碰
out="$(run 'wifi_try_candidates "CZ-305 CZ-BH-407 mm" 1; echo "rc=$? tried=$WIFI_TRY_TOTAL already=$WIFI_TRY_ALREADY_OK"')"
printf '%s' "$out" | grep -q "tried=0" && ok "已能上网时一个网络都不试" || bad "还是试了: $out"
printf '%s' "$out" | grep -q "already=1" && ok "置上 ALREADY_OK 标志" || bad "没置标志: $out"
cur="$(cat "$T/state/current")"
[ "$cur" = "m" ] && ok "当前连接未被改动" || bad "连接被改成 $cur"

echo "=== 15. 失败原因要分类，不能一律说"没有外网" ==="
# 不在范围 vs 连不上 vs 连上没外网，是三回事，用户能采取的行动完全不同
export MOCK_NET_OK="__none__"     # 谁都没有外网
export MOCK_JOIN_OK="CZ-305 mm"   # 这两个"在范围"，其它不在
echo m > "$T/state/current"
out="$(run 'wifi_try_candidates "CZ-305 CZ-BH-407 mm" 1
    echo "total=$WIFI_TRY_TOTAL oor=$WIFI_TRY_OUTOFRANGE jf=$WIFI_TRY_JOINFAIL ni=$WIFI_TRY_NOINET"')"
printf '%s' "$out" | grep -q "total=3" && ok "试了 3 个" || bad "总数错: $out"
printf '%s' "$out" | grep -q "oor=1" && ok "识别出 1 个不在范围（CZ-BH-407）" || bad "不在范围数错: $out"
printf '%s' "$out" | grep -q "ni=2" && ok "识别出 2 个能连上但没外网" || bad "没外网数错: $out"

echo "=== 16. wifi_join 的失败分类 ==="
out="$(run 'wifi_join CZ-BH-407; wifi_join_reason')"
[ "$out" = "outofrange" ] && ok "Could not find network → outofrange" || bad "得到: $out"
out="$(run 'export MOCK_JOIN_FAIL_TEXT="CZ-305"; wifi_join CZ-305; wifi_join_reason')"
[ "$out" = "joinfailed" ] && ok "Failed to join → joinfailed（值得用户关注）" || bad "得到: $out"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

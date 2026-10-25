#!/bin/bash
# 行为测试：cmd_quality 的探测目标必须跟着 PROBE_TARGETS 走
#
# 背景：cmd_quality 曾经把 223.5.5.5 写死。PROBE_TARGETS 是文档里明确开放
# 的配置项（README：「可换成公司内网 IP」），写死它有两个用户可感知的后果：
#
#   1) 用户照文档把 PROBE_TARGETS 换成内网 IP 后，「网速与延迟」页仍然去打
#      223.5.5.5——一个他网络里可能不通的公网地址，于是这一页稳定报 100%
#      丢包，而网络明明是好的。界面显示错比不显示更糟。
#   2) cleanup_probe_routes 是按 PROBE_TARGETS 删路由的（INSTALL.md 承诺
#      「按你配置的 PROBE_TARGETS 删，不限于默认那几个」）。写死的目标不在
#      用户列表里时，加完路由还没删就被杀掉会漏删一条主机路由。
#
# 本文件用 mock ping 记录**实际被打的地址**，把上面两点变成可断言的。
#
# 运行: bash tests/mock_quality_target.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

SRC="$(pwd)/smartroute.sh"
T="$(mktemp -d /tmp/sr_qt.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/log" "$T/run" "$T/etc"
export MOCK_PING_LOG="$T/pings.log" MOCK_ROUTE_LOG="$T/routes.log"

# ping 替身：只记录目标和参数，输出一份合法统计。
# 记录的是**被 ping 的地址**，这正是本测试要断言的东西。
cat > "$T/bin/ping" <<'EOF'
#!/bin/bash
echo "ping $*" >> "$MOCK_PING_LOG"
printf '6 packets transmitted, 6 received, 0.0%% packet loss\n'
printf 'round-trip min/avg/max/stddev = 14.1/14.5/14.9/0.3 ms\n'
exit 0
EOF
# route 替身：记录所有增删。add 一律成功，get 报 en0。
cat > "$T/bin/route" <<'EOF'
#!/bin/bash
echo "route $*" >> "$MOCK_ROUTE_LOG"
case "$*" in
    *get*) printf '   gateway: 192.168.1.1\n  interface: en0\n' ;;
esac
exit 0
EOF
# ifconfig 替身：en0/en1 都有地址（否则 find_active 直接跳过它们）
cat > "$T/bin/ifconfig" <<'EOF'
#!/bin/bash
case "$1" in
    en0) printf '\tinet 192.168.1.50 netmask 0xffffff00 broadcast 192.168.1.255\n' ;;
    en1) printf '\tinet 192.168.1.51 netmask 0xffffff00 broadcast 192.168.1.255\n' ;;
esac
exit 0
EOF
# networksetup 替身：两个硬件端口 + 服务名 + 网关
cat > "$T/bin/networksetup" <<'EOF'
#!/bin/bash
case "$1" in
    -listallhardwareports)
        printf 'Hardware Port: Ethernet\nDevice: en0\n'
        printf 'Hardware Port: Wi-Fi\nDevice: en1\n'
        ;;
    -listnetworkserviceorder)
        printf '(1) Ethernet\n(Hardware Port: Ethernet, Device: en0)\n'
        printf '(2) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en1)\n'
        ;;
    -getinfo) printf 'Router: 192.168.1.1\n' ;;
esac
exit 0
EOF
# id 替身：必须报 0。非 root 时 cmd_quality 不加主机路由，被测分支会被跳过。
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo 0
exit 0
EOF
chmod +x "$T/bin/"*

# 抽出被测函数（入口之前的部分），把绝对路径指到临时目录。
# 注意删掉 PATH= 那一行：不删的话脚本内部会把我们放的 mock 覆盖掉。
sed -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log/l\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/l\"|" \
    -e "s|^PF_ANCHOR_FILE=.*|PF_ANCHOR_FILE=\"$T/etc/anchor\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"

# 跑一次 cmd_quality，PROBE_TARGETS 由调用方给。
# 必须**在 source 之后**再赋值：smartroute.sh 第 68 行有一句默认赋值，
# 先传环境变量会被它覆盖，测到的是默认列表而不是用户配置。
q() {   # $1=PROBE_TARGETS 的值 -> stdout: 命令输出
    printf '%s' "$1" > "$T/pt"
    : > "$MOCK_PING_LOG"; : > "$MOCK_ROUTE_LOG"
    PATH="$T/bin:$PATH" MOCK_PT_FILE="$T/pt" bash -c \
        ". '$T/sr.sh'; PROBE_TARGETS=\"\$(cat \"\$MOCK_PT_FILE\")\"; cmd_quality" 2>/dev/null
}

echo "== 1. 默认列表：打 223.5.5.5（行为不变）=="
out="$(q '223.5.5.5 119.29.29.29 114.114.114.114 1.1.1.1 8.8.8.8')"
grep -q -- '223\.5\.5\.5' "$MOCK_PING_LOG" \
    && ok "默认列表下仍打 223.5.5.5" || bad "默认列表下没打 223.5.5.5"
echo "$out" | grep -q 'loss=0.0%' \
    && ok "两个接口都测出结果" || bad "输出异常: $(echo "$out" | tr '\n' '|')"

echo "== 2. 用户换成公司内网 IP：必须跟着换，不能写死 =="
out="$(q '10.0.0.53 8.8.8.8')"
grep -q -- ' 10\.0\.0\.53' "$MOCK_PING_LOG" \
    && ok "PROBE_TARGETS 换成内网 IP 后打的是 10.0.0.53" \
    || bad "仍在打写死的地址: $(cat "$MOCK_PING_LOG" | tr '\n' '|')"
if grep -q -- '223\.5\.5\.5' "$MOCK_PING_LOG"; then
    bad "换了 PROBE_TARGETS 还在打 223.5.5.5（用户网络里不通 → 这一页假报 100% 丢包）"
else
    ok "不再打用户没配的 223.5.5.5"
fi

echo "== 3. 用户删掉 223.5.5.5：打列表第一个 =="
out="$(q '1.1.1.1 8.8.8.8')"
grep -q -- ' 1\.1\.1\.1' "$MOCK_PING_LOG" \
    && ok "删掉 223.5.5.5 后打 1.1.1.1" || bad "没打 1.1.1.1"

echo "== 4. 加进去的路由必须被 cleanup 覆盖得到 =="
# cleanup_probe_routes 按 PROBE_TARGETS 删。若 add 用的目标不在用户的
# PROBE_TARGETS 里，异常退出（add 之后、delete 之前被杀）就漏删一条主机
# 路由——而 INSTALL.md 承诺的是「按你配置的 PROBE_TARGETS 删」。
# 注意 EXIT trap 也会跑 cleanup，所以路由日志里既有 cmd_quality 的显式删除
# （带 -interface），也有 trap 的兜底删除（不带）。断言前者是后者的子集。
out="$(q '10.0.0.53 8.8.8.8')"
added="$(grep '^route add -host' "$MOCK_ROUTE_LOG" | awk '{print $4}' | sort -u)"
cleaned="$(grep '^route delete -host' "$MOCK_ROUTE_LOG" | awk '{print $4}' | sort -u)"
[ "$added" = "10.0.0.53" ] \
    && ok "加的主机路由目标是 10.0.0.53（=PROBE_TARGETS 第一个）" \
    || bad "加的路由目标是 '$added'，与 PROBE_TARGETS 不一致"
miss=""
for a in $added; do
    printf '%s\n' "$cleaned" | grep -qx "$a" || miss="$miss $a"
done
[ -z "$miss" ] \
    && ok "每个加进去的目标都出现在 cleanup 的删除列表里（异常退出不留孤儿路由）" \
    || bad "这些目标清理不到:$miss"

echo "== 5. PROBE_TARGETS 为空/垃圾：回落默认而不是打空或崩溃 =="
for v in "" "not-an-ip"; do
    out="$(q "$v")"
    if grep -q -- '223\.5\.5\.5' "$MOCK_PING_LOG"; then
        ok "PROBE_TARGETS='$v' → 回落 223.5.5.5"
    else
        bad "PROBE_TARGETS='$v' → 没回落，ping 日志: $(cat "$MOCK_PING_LOG" | tr '\n' '|')"
    fi
    echo "$out" | grep -q 'loss=' || bad "PROBE_TARGETS='$v' 时没有输出结果行"
done

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

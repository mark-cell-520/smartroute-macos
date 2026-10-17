#!/bin/bash
# 行为测试：measure_latency / route_add_host 的出口接口校验
#
# 背景：这台机器两个网卡接同一台路由器——**同网段、同网关**（都是 192.168.1.1）。
# 这个拓扑会同时打穿两道判断：
#
#   1) route_add_host 的兜底分支："已存在的路由网关一致就复用"。
#      同网关下这条永远为真，于是一条指向另一个接口的路由也被判成可复用。
#   2) measure_latency 丢弃了 route_add_host 的返回值，加不加以防万一
#      ping 都会发——走错口也照测，返回一个属于别的接口的延迟。
#
# 后果：MODE=latency 和 balance fastest 会拿着错的延迟选线。用户看到的现象是
# "明明有线延迟低，它偏偏选 Wi-Fi"，而且没有任何报错。
#
# 修法：宁可返回"测不出"，也不能返回假数据。测不出时调用方保持现状，
# 最坏是慢一点；假数据会主动选错线。
#
# 运行: bash tests/mock_probe_iface.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

SRC="$(pwd)/smartroute.sh"
T="$(mktemp -d /tmp/sr_pif.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/log" "$T/run" "$T/etc"
export MOCK_ROUTE_LOG="$T/routes.log" MOCK_PING_LOG="$T/pings.log"
: > "$MOCK_ROUTE_LOG"; : > "$MOCK_PING_LOG"

# route 替身。关键能力：按 MOCK_IFACE_FOR 决定 "route -n get" 报告哪个接口，
# 用来精确复现"已存在路由指向另一个口"这个陷阱。
cat > "$T/bin/route" <<'EOF'
#!/bin/bash
echo "route $*" >> "$MOCK_ROUTE_LOG"
case "$*" in
    add*) exit "${ROUTE_ADD_RC:-0}" ;;
    *get*)
        if [ "${MOCK_IFACE_FOR:-}" = "en1" ]; then
            printf '   gateway: 192.168.1.1\n  interface: en1\n'
        else
            printf '   gateway: 192.168.1.1\n  interface: en0\n'
        fi ;;
esac
exit 0
EOF
# ping 替身：RTT_TAIL 拼出固定平均延迟，便于断言数值
cat > "$T/bin/ping" <<'EOF'
#!/bin/bash
for a in "$@"; do case "$a" in [0-9]*.[0-9]*) t="$a";; esac; done
echo "ping $t" >> "$MOCK_PING_LOG"
printf 'round-trip min/avg/max/stddev = 14.1/14.5/14.9/0.3 ms\n'
EOF
# id 替身：必须报 0。探测路由只在 root 下加，不 mock 的话整个被测代码块
# 会被跳过，测试等于没测。
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo 0
exit 0
EOF
chmod +x "$T/bin/"*

sed -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log/l\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/l\"|" \
    -e "s|^SVC_ORDER_BAK=.*|SVC_ORDER_BAK=\"$T/state/svc\"|" \
    -e "s|^PF_ANCHOR_FILE=.*|PF_ANCHOR_FILE=\"$T/etc/anchor\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"

# 注意：MOCK_IFACE_FOR 必须 export。赋值前缀形式（VAR=x func）不会传给
# 子进程，而 route 是外部命令——不 export 的话 mock 永远看到默认值，
# 陷阱场景就复现不出来。
ml() {   # $1=dev $2=iface_for $3=route_add_rc
    : > "$MOCK_PING_LOG"
    export MOCK_IFACE_FOR="$2" ROUTE_ADD_RC="$3"
    PATH="$T/bin:$PATH" bash -c ". '$T/sr.sh'; measure_latency '$1' 192.168.1.1" 2>/dev/null
}

echo "== 1. 路由正确指向目标接口 → 正常测量 =="
r="$(ml en0 en0 0)"
[ "$r" = "14.5" ] && ok "出口正确时测出延迟（${r}）" || bad "出口正确却返回 '$r'"

echo "== 2. 同网关双口陷阱：已存在路由指向另一个接口 =="
# route add 成功（rc=0），但 route -n get 报告 interface: en1。
# 这是这台机器的真实拓扑，也是原来会静默测错的地方。
r="$(ml en0 en1 0)"
[ -z "$r" ] && ok "出口是别的接口时返回空（拒绝假数据）" || bad "返回了 '$r'，这是属于 en1 的延迟"
_n="$(grep -c '^ping' "$MOCK_PING_LOG")"
[ "$_n" = "0" ] && ok "没有发任何 ping（没拿假数据）" || bad "还是发了 $_n 个 ping"

echo "== 3. route add 全部失败，且已有路由也指向别的接口 =="
r="$(ml en0 en1 1)"
[ -z "$r" ] && ok "加不进去又指错口时返回空" || bad "返回了 '$r'"

echo "== 4. route add 失败，但已有路由确实指向目标接口 =="
# 这种情况复用已有路由是合理的：ping 确实会走 en0，测出来是真的。
r="$(ml en0 en0 1)"
[ "$r" = "14.5" ] && ok "已有路由指向正确接口时允许复用（${r}）" || bad "过于严格，返回 '$r'"

echo "== 5. route_add_host 本身：同网关但不同接口不能判成功 =="
# 这个函数还有其他调用方，不能只在上层打补丁。
export MOCK_IFACE_FOR=en1 ROUTE_ADD_RC=1
out="$(PATH="$T/bin:$PATH" bash -c ". '$T/sr.sh'; route_add_host 223.5.5.5 en0 192.168.1.1; echo rc=\$?" 2>/dev/null)"
echo "$out" | grep -q "rc=1" \
    && ok "网关同、接口不同 → 返回 1（不谎报成功）" || bad "仍返回成功: $out"
# 接口也对时必须返回 0
export MOCK_IFACE_FOR=en0 ROUTE_ADD_RC=1
out="$(PATH="$T/bin:$PATH" bash -c ". '$T/sr.sh'; route_add_host 223.5.5.5 en0 192.168.1.1; echo rc=\$?" 2>/dev/null)"
echo "$out" | grep -q "rc=0" \
    && ok "网关同、接口也同 → 返回 0（合理复用）" || bad "过于严格: $out"

echo "== 6. 非 root 时不应假装能测指定接口 =="
# 非 root 加不了探测路由，ping 只会走默认路由。此时对 en0/en1 会得到
# 同一个数。原来的行为是静默返回那个数，让调用方以为测的是指定接口。
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo 501
exit 0
EOF
chmod +x "$T/bin/id"
: > "$MOCK_PING_LOG"
r="$(ml en0 en0 0)"
[ -n "$r" ] && ok "非 root 仍返回一个值（${r}）" || bad "非 root 直接失败，会破坏 measure 命令"
echo "  （非 root 下这个数属于默认路由，调用方需知晓——见下条断言）"
grep -q 'id -u.*-eq 0' "$SRC" && ok "探测路由仍限于 root" || bad "root 限制被去掉了"
# ensure_latency 必须有非 root 护栏：否则会把默认路由的延迟同时存成
# lat_en0 / lat_en1，状态页显示"两条线都测过"，实际只测了一条。
export MOCK_IFACE_FOR=en0 ROUTE_ADD_RC=0
out="$(PATH="$T/bin:$PATH" bash -c "
    . '$T/sr.sh'
    STATE_FILE='$T/state/state'
    ensure_latency en0 192.168.1.1 en1 192.168.1.1
    echo 'lat_en0='\$(state_get lat_en0)
    echo 'lat_en1='\$(state_get lat_en1)
" 2>/dev/null)"
echo "$out" | grep -q "lat_en0=$" && ok "非 root 不写 lat_en0 缓存（不制造假对称数据）" || bad "非 root 仍写缓存: $out"
echo "$out" | grep -q "lat_en1=$" && ok "非 root 不写 lat_en1 缓存" || bad "非 root 仍写 lat_en1: $out"

echo ""
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

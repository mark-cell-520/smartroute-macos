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
# 修法（v2.13 时代）：宁可返回"测不出"，也不能返回假数据。
#
# [v2.4] 机制已变：measure_latency 主路径改成 ping -b 绑定接口——不依赖
# root、不改路由表，从根上不存在"走错口"（绑定即接口）。旧的主机路由法
# 降级为 -b 全部失败时的兜底（仍保留出口验证）。本文件相应更新：
#   · ping mock 按 -b 的接口返回不同 RTT（en0=14.5 / en1=400.5），
#     "测的是哪个接口"从此可被断言；
#   · 第 6 节非 root 的期望反转：-b 在非 root 下就准，ensure_latency
#     不再需要非 root 早退（那个早退的前提"非 root 只能测到默认路由"
#     已被 -b 推翻），且写进去的两个值必须不同——不同才证明不是
#     默认路由的同一个数。
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
# ping 替身：[v2.4] 按 -b 绑定的接口返回不同 RTT——en0=14.5ms，en1=400.5ms。
# 为什么必须区分：旧 mock 对所有调用返回同一个数，"测的是哪个接口"根本无法
# 断言。v2.4 起 measure_latency 主路径是 ping -b，这个 mock 让"绑定生效"
# 变成可验证的：en1 返回 400.5 而不是 14.5，就证明包真的从 en1 出去了。
cat > "$T/bin/ping" <<'EOF'
#!/bin/bash
prev=""; dev=""
for a in "$@"; do
    [ "$prev" = "-b" ] && dev="$a"
    prev="$a"
done
echo "ping $*" >> "$MOCK_PING_LOG"
if [ "$dev" = "en1" ]; then
    printf 'round-trip min/avg/max/stddev = 400.1/400.5/400.9/0.3 ms\n'
else
    printf 'round-trip min/avg/max/stddev = 14.1/14.5/14.9/0.3 ms\n'
fi
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
grep -q -- "-b en0" "$MOCK_PING_LOG" \
    && ok "用 ping -b 绑定目标接口（v2.4 主路径）" \
    || bad "没有用 -b 绑定接口，又在靠路由表碰运气"

echo "== 2. 同网关双口陷阱：路由表指向别的接口也测不错（v2.4 重写）=="
# route add 成功（rc=0），但 route -n get 报告 interface: en1——这台机器的
# 真实拓扑。旧机制在这里全军覆没：出口验证发现走的是 en1 → 跳过全部目标
# → 返回空 → lat_en1 永久缺失（Wi-Fi 网关 RTT 恶化到 1.1 秒都没触发切换）。
# 新机制 ping -b en0：绑定即接口，路由表状态不影响测量对象。
r="$(ml en0 en1 0)"
[ "$r" = "14.5" ] && ok "路由表指向 en1 时仍测到 en0 的 14.5ms（绑定优先于路由表）" \
    || bad "返回 '$r'——要么空（旧病复发）要么是 en1 的 400.5（走错口）"
grep -q -- "-b en0" "$MOCK_PING_LOG" \
    && ok "ping 确实绑定 en0（不是碰运气走到 en0）" || bad "ping 没有绑定 en0"

echo "== 3. Wi-Fi 侧（en1）必须测得到——旧机制下它永远缺失 =="
# 这是 v2.4 要修的核心病灶：同网关双接口机器上，旧主机路由法给 en1 加路由
# 会加错口，lat_en1 连续多轮为空，auto 的延迟一票否决因"一边没数据"
# 持续弃权。现在 ping -b en1 直接测。
r="$(ml en1 en1 0)"
[ "$r" = "400.5" ] && ok "measure_latency en1 返回 400.5ms（Wi-Fi 侧不再缺失）" \
    || bad "en1 返回 '$r'，期望 400.5"
echo "== 3b. route add 全部失败也不影响 -b 测量 =="
r="$(ml en0 en1 1)"
[ "$r" = "14.5" ] && ok "路由加不进去仍测到 en0 的 14.5ms（-b 不依赖路由操作）" \
    || bad "返回 '$r'"

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

echo "== 6. 非 root 也能分别测两个接口（v2.4 重写）=="
# 旧前提"非 root 加不了探测路由 → 两次调用测的都是默认路由 → 得到同一个数"
# 已被 ping -b 推翻：绑定接口不需要 root。实测普通用户下
# ping -b en0=42ms / ping -b en1=524ms，分别测得准。
# 所以 ensure_latency 的非 root 早退已移除；本节的"假对称"防线改成：
# 两个缓存值必须不同——不同才证明各测各的，不是默认路由的同一个数。
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo 501
exit 0
EOF
chmod +x "$T/bin/id"
: > "$MOCK_PING_LOG"
r0="$(ml en0 en0 0)"; r1="$(ml en1 en1 0)"
[ "$r0" = "14.5" ] && [ "$r1" = "400.5" ] \
    && ok "非 root 下两口分别测得 14.5 / 400.5（不再是同一个数）" \
    || bad "非 root 测量异常: en0=$r0 en1=$r1（相同就是旧病复发）"
grep -q 'id -u.*-eq 0' "$SRC" && ok "主机路由兜底仍限于 root（-b 是主路径）" || bad "root 限制被去掉了"
export MOCK_IFACE_FOR=en0 ROUTE_ADD_RC=0
out="$(PATH="$T/bin:$PATH" bash -c "
    . '$T/sr.sh'
    STATE_FILE='$T/state/state'
    ensure_latency en0 192.168.1.1 en1 192.168.1.1
    echo 'lat_en0='\$(state_get lat_en0)
    echo 'lat_en1='\$(state_get lat_en1)
" 2>/dev/null)"
echo "$out" | grep -q "lat_en0=14.5" && ok "非 root 也写 lat_en0=14.5（数据是准的）" || bad "lat_en0 异常: $out"
echo "$out" | grep -q "lat_en1=400.5" && ok "非 root 也写 lat_en1=400.5（两口数据不同=真测了）" || bad "lat_en1 异常: $out"

echo ""
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# 自适应扩连（adaptive ramp-up）行为测试
#
# 背景：实测连接数是有峰值的，超过之后吞吐单调下降、失败分片等比例增加：
#     n=2   218MB  1 个分片失败   17.0 Mbps
#     n=4   219MB  2 个分片失败   17.6 Mbps   ← 峰值
#     n=8   178MB  4 个分片失败   14.3 Mbps
#     n=16   97MB  11 个分片失败   8.0 Mbps
# 而"峰值是多少"取决于服务端，用户没法预知。所以 fetch 改成先起 2 条，
# 之后每当"已下完片数 ≥ 下一档阈值"才加一条，直到用户给的 -n 上限。
#
# 这个测试要回答三个问题（都必须是**真跑 HTTP**，不能只 grep 源码）：
#   1. 快服务端 → 真的会往上加（加人逻辑没死）
#   2. 慢服务端 → 不会盲目加到上限（收敛逻辑生效）
#   3. 任何情况下都不超过用户给的 -n
#
# 运行: bash tests/mock_fetch_ramp.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_ramp.XXXXXX)"
trap 'rm -rf "$T"; pkill -f httpstub_ramp 2>/dev/null' EXIT

# ── 环境隔离 ──
# smartroute.sh 在 source 时无条件重置 PATH，并把 STATE_FILE/LOG_FILE 等
# 指向 /var/log、/var/db（非 root 写不进去）。所以不能用 source + 调函数
# 的方式，而是整脚本跑，靠这些变量在子进程里覆盖。
# 注意：必须 export，子进程的 smartroute.sh 才会看到。
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$T/state" "$T/lock" "$T/log"
export STATE_FILE="$T/state/state"
export LOG_FILE="$T/log/smartroute.log"
export SVC_ORDER_BAK="$T/state/svc_order_orig"
export LOCK_DIR="$T/lock"
export PF_ANCHOR_FILE="$T/anchor"

PORT=18877
python3 tests/httpstub.py "$PORT" >/dev/null 2>&1 &
STUB=$!
# 等端口起来。以前不等待：桩还没 listen 就去探测，fetch 报"连接失败"，
# 然后整个测试因为一个时序问题挂掉，看起来像功能坏了。
_i=0
while [ "$_i" -lt 50 ]; do
    curl -sS -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/size/10" 2>/dev/null && break
    _i=$((_i+1)); sleep 0.2
done
if [ "$_i" -ge 50 ]; then
    echo "桩没起来，测试中止"
    exit 1
fi

# 跑一次 fetch，把输出存到 $T/out。<URL> <n> [输出文件]
run_fetch() {   # $1=URL $2=n
    bash smartroute.sh fetch "$1" -o "$T/dl.bin" -n "$2" --no-balance-check \
        > "$T/out" 2>&1
}

echo "== 1. 快服务端：-n 8 应该往上加 =="
# 40MB / 32 片，本地桩几乎无延迟。先起 2 条，下完 2 片就该加到 3 条。
run_fetch "http://127.0.0.1:$PORT/size/40000000" 8
grep -q "自适应扩连：从 2 条逐步加到" "$T/out" \
    && ok "快服务端触发了扩连" || bad "快服务端没扩连（加人逻辑失效）"
_ramped="$(sed -n 's/.*逐步加到 \([0-9]*\) 条.*/\1/p' "$T/out" | head -1)"
[ -n "$_ramped" ] && [ "$_ramped" -ge 3 ] \
    && ok "扩连后连接数 ≥ 3（实际 $_ramped）" || bad "扩连后连接数异常（${_ramped:-未捕获}）"
[ -n "$_ramped" ] && [ "$_ramped" -le 8 ] \
    && ok "没超过用户上限 8（实际 $_ramped）" || bad "超过了用户上限 8（实际 ${_ramped:-?}）"
[ "$(wc -c < "$T/dl.bin" | tr -d ' ')" = "40000000" ] \
    && ok "文件字节数正确" || bad "文件字节数不对"
python3 -c "
import sys
d=open('$T/dl.bin','rb').read()
sys.exit(0 if d==b'B'*len(d) else 1)" \
    && ok "文件内容逐字节正确" || bad "文件内容损坏"

echo "== 2. 慢服务端：-n 8 不该盲目加满 =="
# 每片睡 700ms。起 2 条时下完 2 片要约 1.4s；阈值会随连接数水涨船高，
# 但慢服务端下片的速度跟不上阈值增长，所以连接数应该停在低位。
run_fetch "http://127.0.0.1:$PORT/slowsize/12000000/700" 8
_slow="$(sed -n 's/.*逐步加到 \([0-9]*\) 条.*/\1/p' "$T/out" | head -1)"
if [ -z "$_slow" ]; then
    ok "慢服务端没有扩连（始终 2 条，收敛生效）"
else
    [ "$_slow" -le 4 ] \
        && ok "慢服务端只加到 ${_slow} 条（未盲目加满 8）" \
        || bad "慢服务端加到了 ${_slow} 条，收敛失效"
fi
[ "$(wc -c < "$T/dl.bin" | tr -d ' ')" = "12000000" ] \
    && ok "慢速文件也下完了" || bad "慢速文件没下完"
python3 -c "
import sys
d=open('$T/dl.bin','rb').read()
sys.exit(0 if d==b'C'*len(d) else 1)" \
    && ok "慢速文件内容正确" || bad "慢速文件内容损坏"

echo "== 3. -n 1 和 -n 2 不该触发扩连 =="
# n_start = min(n,2)，n≤2 时一开始就起满了，没有"逐步加"的余地。
for _n in 1 2; do
    run_fetch "http://127.0.0.1:$PORT/size/8000000" "$_n"
    if grep -q "自适应扩连：从" "$T/out"; then
        bad "-n $_n 也打印了扩连（本该起满即止）"
    else
        ok "-n $_n 不触发扩连"
    fi
    [ "$(wc -c < "$T/dl.bin" | tr -d ' ')" = "8000000" ] \
        && ok "-n $_n 文件正确" || bad "-n $_n 文件不对"
done

echo "== 4. 扩连过程本身不能把文件下坏 =="
# 这是最关键的一条：worker 是动态加的，新旧 worker 共享认领队列。
# 如果动态 spawn 破坏了队列语义，会出现重复下某片或漏下某片。
# 32 片、-n 8，足够让扩连发生多次。
run_fetch "http://127.0.0.1:$PORT/size/40000000" 8
_nchunks="$(sed -n 's/.*切成 \([0-9]*\) 片.*/\1/p' "$T/out" | head -1)"
[ "$(wc -c < "$T/dl.bin" | tr -d ' ')" = "40000000" ] \
    && ok "动态加 worker 后文件完整（$_nchunks 片）" || bad "动态加 worker 后文件缺片/多片"
grep -q "失败\|不一致" "$T/out" \
    && bad "快服务端下载报了失败" || ok "没有误报失败"

echo ""
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

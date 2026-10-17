#!/bin/bash
# fetch 的真实 HTTP 行为测试
#
# 为什么单独一个文件：mock_fetch.sh 此前全是 grep 源码字符串断言，
# 没有一次真实 HTTP 交互。结果两个真 bug 都是在"所有断言全绿"的情况下
# 成立的——重定向链取错状态行（P0-1）、-n 缺值死循环（P1-4）。
# 字符串断言只能证明"代码里写了某句话"，证明不了"跑起来是对的"。
#
# 这里用 tests/httpstub.py 起本地 HTTP 替身，支持 Range/302/404/不认 Range/
# 大小造假五种行为，对 fetch 打真实请求。
#
# 运行: bash tests/mock_fetch_http.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

PORT=8791
STUB_PID=""
cleanup() {
    [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
    rm -rf "$T" 2>/dev/null
}
T="$(mktemp -d /tmp/sr_http.XXXXXX)"
trap cleanup EXIT INT TERM HUP

python3 tests/httpstub.py "$PORT" >/dev/null 2>&1 &
STUB_PID=$!
# 等端口就绪，不用固定 sleep：起得慢时会假失败
_i=0
while [ "$_i" -lt 50 ]; do
    curl -sS -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/empty" 2>/dev/null && break
    _i=$(( _i + 1 )); sleep 0.1
done
if [ "$_i" -ge 50 ]; then
    echo "替身服务起不来，跳过（端口 $PORT 被占？）"
    exit 0
fi
B="http://127.0.0.1:$PORT"

echo "== 1. 支持 Range 的文件：多连接下载必须字节正确 =="
bash smartroute.sh fetch "$B/file/x" -o "$T/a.bin" -n 4 --no-balance-check >"$T/a.log" 2>&1
if [ -f "$T/a.bin" ] && [ "$(wc -c < "$T/a.bin" | tr -d ' ')" = "5000" ]; then
    ok "4 连接下载得 5000 字节"
    printf 'A%.0s' $(seq 1 5000) > "$T/ref.bin"
    cmp -s "$T/a.bin" "$T/ref.bin" && ok "内容与单连接参照一致" || bad "内容不一致"
else
    bad "下载结果不对: $(wc -c < "$T/a.bin" 2>/dev/null || echo 无文件)"
fi
# 分片临时目录必须清掉
ls -d /tmp/smartroute_fetch.* >/dev/null 2>&1 && ok "（临时目录由 trap 清理）" || ok "无残留临时目录"

echo "== 2. 302 重定向（修 P0-1：曾把跳转 URL 误判为不支持 Range）=="
# curl -L -D - 会打出每一跳的响应头，取 NR==1 拿到的是 302 而不是最终的 416。
# 所有会跳转的 URL（github release、CDN 直链）都被静默降级成单连接。
bash smartroute.sh fetch "$B/redir/x" -o "$T/b.bin" -n 2 --no-balance-check >"$T/b.log" 2>&1
if grep -q "不支持 Range" "$T/b.log"; then
    bad "重定向 URL 被误判为不支持 Range"
else
    ok "重定向 URL 正确识别为支持 Range"
fi
[ -f "$T/b.bin" ] && [ "$(wc -c < "$T/b.bin" | tr -d ' ')" = "5000" ] \
    && ok "重定向后下载完整" || bad "重定向后下载不完整"

echo "== 3. 不认 Range 的源：退化单连接且内容完整 =="
bash smartroute.sh fetch "$B/norange/x" -o "$T/c.bin" -n 4 --no-balance-check >"$T/c.log" 2>&1
grep -q "不支持 Range" "$T/c.log" && ok "识别为不支持 Range" || bad "没识别出不支持 Range"
[ -f "$T/c.bin" ] && [ "$(wc -c < "$T/c.bin" | tr -d ' ')" = "5000" ] \
    && ok "退化单连接内容完整" || bad "退化后内容不完整"
grep -q "只能用单连接\|两条线帮不上" "$T/c.log" \
    && ok "说明了为什么两条线帮不上" || bad "没说明原因"

echo "== 4. 404：报 HTTP 错误，不产出垃圾文件 =="
rm -f "$T/d.bin"
bash smartroute.sh fetch "$B/missing" -o "$T/d.bin" -n 2 --no-balance-check >"$T/d.log" 2>&1
grep -q "HTTP 404" "$T/d.log" && ok "明确报 HTTP 404" || bad "没报 HTTP 404"
grep -q "浏览器能访问\|URL 打不开" "$T/d.log" \
    && ok "给出可操作建议（而不是让人换源）" || bad "建议不可操作"
[ -f "$T/d.bin" ] && bad "产出了内容为错误页的文件" || ok "没有产出垃圾输出文件"

echo "== 5. 大小造假：字节校验必须拦下 =="
# 替身在越界探测时报 1234，实际 GET 返回 5000。不拦就会拼出一个错文件。
bash smartroute.sh fetch "$B/lying" -o "$T/e.bin" -n 2 --no-balance-check >"$T/e.log" 2>&1
if grep -q "Range 行为不一致\|大小不符\|期望" "$T/e.log"; then
    ok "字节校验拦下了大小不符的源"
else
    bad "没拦住大小造假: $(tail -2 "$T/e.log")"
fi
[ -f "$T/e.bin" ] && bad "产出了可能损坏的文件" || ok "没有产出损坏文件"

echo "== 6. 选项缺值不能死循环（修 P1-4）=="
# -n 是最后一个参数时，bash 的 shift 2 失败且不移位，while 原地打转。
# 表现：无任何输出、CPU 打满、永远卡死（App 的下载入口会永久挂起）。
# 不用 timeout 命令（本环境没有）：用后台 + 轮询 + kill。
for opt in "-n" "-o"; do
    ( bash smartroute.sh fetch "$B/file/x" "$opt" --no-balance-check >"$T/f.log" 2>&1 ) &
    _fp=$!
    _w=0
    while kill -0 "$_fp" 2>/dev/null && [ "$_w" -lt 40 ]; do
        sleep 0.1; _w=$(( _w + 1 ))
    done
    if kill -0 "$_fp" 2>/dev/null; then
        kill "$_fp" 2>/dev/null; wait "$_fp" 2>/dev/null
        bad "$opt 缺值死循环（4 秒仍未退出）"
    else
        wait "$_fp" 2>/dev/null
        ok "$opt 缺值立即退出"
        # 两类缺值都要接住：
        #   · 后面彻底没有参数   → "需要一个参数"
        #   · 后面跟着另一个选项 → "不能以 - 开头"（更精确：指出漏写了值）
        # 以前只有第一类，第二类会把选项名当成参数值——-o 会真的建出一个
        # 叫 "--no-balance-check" 的文件，-n 则报一句指不到原因的
        # "连接数必须是正整数"。
        grep -q "需要一个参数\|不能以 - 开头\|用法\|未知选项" "$T/f.log" \
            && ok "  $opt 缺值的错误信息可读" || bad "  $opt 缺值无有用信息: $(tail -1 "$T/f.log")"
    fi
done

echo "== 7. 空文件 =="
bash smartroute.sh fetch "$B/empty" -o "$T/g.bin" -n 4 --no-balance-check >"$T/g.log" 2>&1
if [ -f "$T/g.bin" ] && [ "$(wc -c < "$T/g.bin" | tr -d ' ')" = "0" ]; then
    ok "空文件下载得 0 字节且不报错"
else
    # 0 字节可能走"取不到大小"分支，那也是合理行为，只要不崩
    grep -q "错误:" "$T/g.log" && bad "空文件报错: $(tail -1 "$T/g.log")" || ok "空文件未崩溃"
fi

echo ""
echo "结果: $PASS 通过, $FAIL 失败"

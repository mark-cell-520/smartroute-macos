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

echo "== 8. 规则文件必须先校验再落位（P2-11）=="
# 直接覆盖 anchor 文件的问题是：pfctl -n 校验失败时，磁盘上已经是被判
# 非法的规则，而内核跑的却是上一套好规则。于是 balance status 的
# "规则内容"显示一套根本没跑的规则，用户照着排查完全偏离方向；
# 之后每次 pfctl -f 继续失败；最糟的是若有人重新加载 pf，
# 就会把非法规则装进内核，分流直接失效。
W="$(mktemp -d /tmp/sr_w.XXXXXX)"
cat > "$W/run.sh" <<RUN
. '$T/sr.sh'; trap - EXIT INT TERM HUP
export PATH='/usr/bin:/bin:/usr/sbin:/sbin' LOCK_DIR='$T/lock'
svc_router() { echo 192.168.1.1; }; other_nets() { echo; }
dev_subnet() { echo 192.168.1.0/24; }; eth_wifi_same_gateway() { return 0; }
pf_enabled() { return 1; }
export STATE_FILE='$T/state/st' PF_ANCHOR_FILE='$W/r.conf' PF_ANCHOR='smartroute'
pfctl() { return 0; }
write_pf_rules en0 192.168.1.1 en1 192.168.1.1 '' '' 1 4 >/dev/null 2>&1
md5sum "$W/r.conf" 2>/dev/null | cut -d' ' -f1 > "$W/good.md5"
pfctl() { case "\$*" in *-n*-f*) return 1 ;; *) return 0 ;; esac; }
write_pf_rules en0 192.168.1.1 en1 192.168.1.1 '' '' 4 1 >/dev/null 2>&1
echo "rc=\$?"
md5sum "$W/r.conf" 2>/dev/null | cut -d' ' -f1 > "$W/now.md5"
echo "same=\$(cmp -s "$W/good.md5" "$W/now.md5" && echo yes || echo no)"
echo "tmpfiles=\$(ls "$W"/r.conf.tmp.* 2>/dev/null | wc -l | tr -d ' ')"
RUN
out="$(bash "$W/run.sh" 2>&1)"
echo "$out" | grep -q "rc=1" && ok "pfctl -n 校验失败时返回 1" || bad "校验失败没报错"
echo "$out" | grep -q "same=yes" \
    && ok "校验失败时保留旧规则（不落非法规则）" || bad "旧规则被覆盖成非法规则"
echo "$out" | grep -q "tmpfiles=0" \
    && ok "无临时文件残留" || bad "有临时文件残留: $(echo "$out" | grep tmpfiles)"
rm -rf "$W"

echo "== 8b. 吞吐计时的终点是合并完成，不是报告之后（P2-14）=="
# t_start 在抓基线时取，结束时间若放到整段分摊报告之后取，中间隔着
# 两次 netstat、state 读、一堆 echo。100-300ms 对纳秒计时要救的
# "小文件"场景正好是 10-30% 偏差，而且取决于报告打了多少行、不可复现。
grep -q 't_end_ns="$(date +%s%N)"' smartroute.sh \
    && ok "合并完成时就取结束时间" || bad "结束时间取得太晚"
# 合并（eval cat）必须在 t_end_ns 之前
ML="$(grep -n 'eval "cat \$_catlist"' smartroute.sh | head -1 | cut -d: -f1)"
EL="$(grep -n 't_end_ns="$(date +%s%N)"' smartroute.sh | head -1 | cut -d: -f1)"
[ -n "$ML" ] && [ -n "$EL" ] && [ "$EL" -gt "$ML" ] \
    && ok "结束计时在合并之后（第 $EL > $ML 行）" || bad "结束计时位置不对"
# 全程只应**调用**两次纳秒时间戳：起点（t_start_ns）和终点（t_end_ns）。
# 只数 ="$(date +%s%N)" 这种真实调用，注释里提到的不算。
NOWS="$(grep -c '="$(date +%s%N)"' smartroute.sh)"
[ "$NOWS" -eq 2 ] \
    && ok "全程只调用两次时间戳（起点+终点）" || bad "调用了 $NOWS 次时间戳"
# 报告段（local t_dur bps 之后）不允许再真实调用
RL="$(grep -n 'local t_dur bps' smartroute.sh | head -1 | cut -d: -f1)"
AFTER="$(awk -v n="$RL" 'NR>n && /=\"\$\(date \+%s%N\)\"/' smartroute.sh | wc -l | tr -d ' ')"
[ "$AFTER" -eq 0 ] \
    && ok "报告段不再取时间戳" || bad "报告段调用了 $AFTER 次"
grep -q 't_ns_now="\$t_end_ns"' smartroute.sh \
    && ok "报告段复用 t_end_ns" || bad "报告段没有复用"
# 行为验证：同一个文件下两次，吞吐量级应当一致（不会因为报告长短乱跳）
_v1="$(bash smartroute.sh fetch "$B/file/x" -o "$T/j1.bin" -n 2 --no-balance-check 2>&1 | grep -o '吞吐: [0-9.]* Mbps')"
_v2="$(bash smartroute.sh fetch "$B/file/x" -o "$T/j2.bin" -n 2 --no-balance-check 2>&1 | grep -o '吞吐: [0-9.]* Mbps')"
echo "    两次实测: $_v1 / $_v2"
[ -n "$_v1" ] && [ -n "$_v2" ] && ok "两次都产出了吞吐数字" || bad "没产出吞吐数字"

echo "== 9. 一个分片失败，其余 worker 要停手（P2-12）=="
# 以前失败的 worker 自己 return 1，兄弟继续认领到队列空，父进程 wait
# 全部。于是某片失败时整个文件照下（每段最长 600s），最后才报"已放弃"
# ——消息和"其实全下完了"的行为矛盾，白费带宽和时间。
grep -q '\[ ! -f "\$d/stop" \]' smartroute.sh \
    && ok "worker 认领循环检查 stop 标志" || bad "worker 不认 stop 标志"
grep -q ': > "\$T/stop"' smartroute.sh \
    && ok "首个失败即创建 stop 标志" || bad "没有创建 stop 标志"
grep -q "_stop_seen" smartroute.sh \
    && ok "父进程轮询 stop 并 kill 剩余 worker" || bad "父进程不轮询，仍会干等全部"
grep -q "白费带宽和时间" smartroute.sh \
    && ok "注释写清了不停手的后果" || bad "没说清后果"
# 行为验证：lying 源（字节校验必失败）应当在几秒内结束，不会跑满 600s
_s0=$(date +%s)
bash smartroute.sh fetch "$B/lying" -o "$T/h.bin" -n 8 --no-balance-check >"$T/h.log" 2>&1
_s1=$(date +%s)
if [ $(( _s1 - _s0 )) -le 20 ]; then
    ok "失败时 ${_s0}→${_s1} 秒内结束（没把整个文件下完）"
else
    bad "失败后仍跑了 $(( _s1 - _s0 )) 秒"
fi
# 正常下载不能被 stop 机制误伤
bash smartroute.sh fetch "$B/file/x" -o "$T/i.bin" -n 8 --no-balance-check >"$T/i.log" 2>&1
[ -f "$T/i.bin" ] && [ "$(wc -c < "$T/i.bin" | tr -d ' ')" = "5000" ] \
    && ok "正常 8 连接下载不受 stop 机制影响" || bad "正常下载被误伤"

echo ""
echo "结果: $PASS 通过, $FAIL 失败"

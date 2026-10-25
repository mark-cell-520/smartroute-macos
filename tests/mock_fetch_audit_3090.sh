#!/bin/bash
# cmd_fetch 后半部分（smartroute.sh 3090-3785：分片认领队列 / worker 并发 /
# _fetch_seg 重试与失败分类 / _fetch_worker / 合并 / 字节与内容校验 /
# 吞吐计算 / 自适应扩连）的问题复现脚本。
#
# 行号按 2026-10-25 工作区（另一处新增 35 行后，3090-3785 平移到 3125-3820）。
# 每个小节对应一个已确认的问题，跑法是"真打 HTTP"：起一个本地桩，用真实
# curl + 真实 smartroute.sh 跑完整下载，然后看输出和桩的请求日志。
#
# 运行: bash tests/mock_fetch_audit_3090.sh
# 退出码: 全部复现成功 = 0（= 这些 bug 都在），有任何一节没复现 = 1。
#
# ⚠️ 这个脚本是"复现 bug"用的，不是防腐烂测试：它断言的是**错误行为存在**。
# 修好之后这些断言会变红——那时应该把它改成断言正确行为（或删掉）。
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
# 标签从"复现/未复现"改成 OK/XX：这个文件现在是回归测试，
# 再印"未复现"会让人以为要它复现什么。
ok()  { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
miss(){ FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_audit3090.XXXXXX)"
trap 'rm -rf "$T"; [ -n "${STUB:-}" ] && kill "$STUB" 2>/dev/null' EXIT

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$T/state" "$T/lock" "$T/log"
export STATE_FILE="$T/state/state"
export LOG_FILE="$T/log/smartroute.log"
export SVC_ORDER_BAK="$T/state/svc_order_orig"
export LOCK_DIR="$T/lock"
export PF_ANCHOR_FILE="$T/anchor"

PORT=$(( 20000 + ( $$ % 20000 ) ))     # 随机端口，避免和上次残留的桩撞上
cat > "$T/stub.py" <<'STUBEOF'
#!/usr/bin/env python3
"""审计用 HTTP 桩：支持多种故障注入。用法: stub.py <端口> <日志文件>

路径（n=文件字节数）：
  /size/<n>                 正常，完整 Range
  /e429/<n>                 所有分片请求都回 429（探测/HEAD 正常回答）
  /first429/<n>             第 1 个分片请求回 429，其余全部快速成功
  /trickle/<n>/<ms>         头立即发，body 分 20 段慢速给完（慢但持续的链路）
  /trickle429/<n>/<ms>/<k>  慢速 + 第 k 个分片请求回 429（持续扛不住）
  /one404/<n>/<off>/<ms>    start==<off> 的分片回 404，其余拖 ms 给 body
  /hang404/<n>/<off>        start==<off> 的分片回 404，其余头发完就再也不给 body
  /tail429/<n>/<k>          全局第 k 个请求之后全部回 429
"""
import sys, threading, time
from http.server import BaseHTTPRequestHandler
from socketserver import ThreadingTCPServer

LOGF = None
LOCK = threading.Lock()
SEGCOUNT = {}
ALLREQ = [0]

def log(msg):
    with LOCK:
        with open(LOGF, 'a') as f:
            f.write("%.3f %s\n" % (time.time(), msg))

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a):
        pass

    def _range(self):
        r = self.headers.get('Range')
        if not r:
            return None
        try:
            a, b = r.split('=')[1].split('-')
            return int(a), (int(b) if b else None)
        except Exception:
            return None

    def _send(self, code, hdrs, body=b'', head_only=False):
        self.send_response(code)
        for k, v in hdrs:
            self.send_header(k, v)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if head_only or not body:
            return
        try:
            self.wfile.write(body)
            self.wfile.flush()
            log("DONE %s len=%d" % (self.path, len(body)))
        except Exception as e:
            log("BODYFAIL %s %s" % (self.path, e))

    def do_HEAD(self):
        self.route(head_only=True)

    def do_GET(self):
        self.route(head_only=False)

    def route(self, head_only):
        p = self.path.split('?')[0]
        parts = [x for x in p.strip('/').split('/') if x != '']
        kind = parts[0] if parts else ''
        try:
            n = int(parts[1])
        except Exception:
            n = 0
        with LOCK:
            ALLREQ[0] += 1
            alln = ALLREQ[0]
        rng = self._range()
        if rng is None or rng[0] >= n:
            # 越界探测 / HEAD：按正常服务器回答（让 fetch 拿到大小）
            log("PROBE %s range=%s" % (p, rng))
            if head_only:
                self._send(200, [('Content-Type', 'application/octet-stream'),
                                 ('Accept-Ranges', 'bytes')], b'', head_only=True)
            else:
                self._send(416, [('Content-Range', 'bytes */%d' % n)])
            return
        # 真分片 = 范围长度 > 1 的请求。接口探测用 -r 0-0（1 字节），单独记，
        # 不占用分片序号——否则故障注入的阈值会随探测次数漂移。
        real = (rng[1] is None or rng[1] - rng[0] > 1)
        with LOCK:
            if real:
                SEGCOUNT[kind] = SEGCOUNT.get(kind, 0) + 1
            seq = SEGCOUNT.get(kind, 0)
        if not real:
            log("IPROBE %s range=%s" % (p, rng))
        else:
            log("SEG %s seq=%d range=%s" % (p, seq, rng))
        if kind == 'tail429' and seq > int(parts[2]):
            log("TAIL429 %s seq=%d" % (p, seq))
            self._send(429, [('Content-Type', 'text/plain')], b'rate limited', head_only)
            return
        a = rng[0]
        b = n - 1 if rng[1] is None else min(rng[1], n - 1)
        body = (b'X' * n)[a:b + 1]

        if kind == 'e429':
            self._send(429, [('Content-Type', 'text/plain')], b'rate limited', head_only)
            return
        if kind == 'first429':
            if seq == 1:
                self._send(429, [('Content-Type', 'text/plain')], b'rate limited', head_only)
                return
            self._send(206, [('Content-Type', 'application/octet-stream'),
                             ('Content-Range', 'bytes %d-%d/%d' % (a, b, n))], body, head_only)
            return
        if kind in ('trickle', 'trickle429'):
            if kind == 'trickle429' and seq % int(parts[3]) == 0:
                self._send(429, [('Content-Type', 'text/plain')], b'rate limited', head_only)
                return
            total_ms = int(parts[2])
            self.send_response(206)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Range', 'bytes %d-%d/%d' % (a, b, n))
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            if head_only:
                return
            pieces = 20
            step = max(1, len(body) // pieces)
            for off in range(0, len(body), step):
                time.sleep(total_ms / 1000.0 / pieces)
                try:
                    self.wfile.write(body[off:off + step]); self.wfile.flush()
                except Exception as e:
                    log("BODYFAIL %s %s" % (self.path, e)); return
            log("DONE %s len=%d" % (self.path, len(body)))
            return
        if kind == 'one404':
            off = int(parts[2]); ms = int(parts[3]) / 1000.0
            if a == off:
                self._send(404, [('Content-Type', 'text/plain')], b'not found', head_only)
                return
            self._send(206, [('Content-Type', 'application/octet-stream'),
                             ('Content-Range', 'bytes %d-%d/%d' % (a, b, n))], body, head_only)
            time.sleep(ms)
            return
        if kind == 'hang404':
            off = int(parts[2])
            if a == off:
                self._send(404, [('Content-Type', 'text/plain')], b'not found', head_only)
                return
            self.send_response(206)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Range', 'bytes %d-%d/%d' % (a, b, n))
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            if head_only:
                return
            time.sleep(120)      # 永不返回 body，逼 curl 的 speed-time 中止
            return
        # /size/<n>
        self._send(206, [('Content-Type', 'application/octet-stream'),
                         ('Content-Range', 'bytes %d-%d/%d' % (a, b, n))], body, head_only)

if __name__ == '__main__':
    port = int(sys.argv[1]); LOGF = sys.argv[2]
    globals()['LOGF'] = LOGF
    class Srv(ThreadingTCPServer):
        daemon_threads = True
        allow_reuse_address = True
    Srv(('0.0.0.0', port), H).serve_forever()   # 绑全网卡：1b 节要打局域网 IP
STUBEOF

python3 "$T/stub.py" "$PORT" "$T/hits.log" >"$T/stub.err" 2>&1 &
STUB=$!
_i=0
while [ "$_i" -lt 50 ]; do
    curl -sS -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/size/10" 2>/dev/null && break
    _i=$((_i+1)); sleep 0.2
done
if [ "$_i" -ge 50 ]; then echo "桩没起来，测试中止"; exit 1; fi

# 跑一次 fetch：$1=路径 $2=-n
run_fetch() {   # -> 输出进 $T/out，退出码进 $T/rc
    : > "$T/hits.log"
    bash smartroute.sh fetch "http://127.0.0.1:$PORT$1" -o "$T/dl.bin" \
         -n "${2:-4}" --no-balance-check > "$T/out" 2>&1
    echo $? > "$T/rc"
}
# 同上，但打本机局域网 IP（让 --interface 探测能过，_spread_devs 非空）
run_fetch_lan() {   # $1=路径 $2=-n
    : > "$T/hits.log"
    bash smartroute.sh fetch "http://$LAN_IP:$PORT$1" -o "$T/dl.bin" \
         -n "${2:-4}" --no-balance-check > "$T/out" 2>&1
    echo $? > "$T/rc"
}

echo "== 1. 服务端 429（限流）被诊断为「服务端 Range 行为不一致，请换源」=="
# 桩的行为：越界探测回 416 + Content-Range（服务端明明支持 Range），HEAD 回
# 正确大小，只有分片请求回 429。也就是说工具自己刚证明过"这个源支持 Range"，
# 失败时却说它 Range 行为不一致、让用户换源——而 429 的正确处置是降 -n。
run_fetch /e429/8000000 4
grep -q "Range 行为不一致" "$T/out" && miss "429 仍被误诊成 Range 行为不一致" \
    || ok "没有 Range 误诊"
grep -q "请换一个源" "$T/out" && miss "仍在让用户换源（错误建议）" || ok "没让换源"
grep -qi "限流\|先把 -n 降到 2\|HTTP 429" "$T/out" \
    && ok "说清了是限流，并给了降 -n 的处置" \
    || miss "全程不提 429/限流——正确处置被吞掉，用户只能瞎猜"
grep -q "分片 0 期望 2000000 字节、实得 0 字节" "$T/out" \
    && miss "仍把无意义的字节数（429 没有字节数可言）当证据" || ok "字节数文案已改"

echo "== 1b. 同一个 429 还被记成「网卡连续失败」=="
# _fetch_seg 的跨接口兜底在 3 次重试都失败后调 _fetch_dev_fail \$dev，
# 不区分"这条线不通"和"服务端限流"。两个 worker 都在 en0 上撞 429 → 计数到 2
# → 打出"en0 连续失败，已停止往它派片"。而 en0 刚刚还成功探过（206）。
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null)"
if [ -n "$LAN_IP" ]; then
    run_fetch_lan /e429/8000000 4
    grep -q "分片将分摊到 en0" "$T/out" && ok "分片确实绑在 en0 上（探测通过，线是好的）" \
        || miss "没能绑到 en0（本节跳过）"
    grep -q "en0 连续失败" "$T/out" && miss "en0 仍被冤枉成连续失败（服务端 429 记到网卡账上）" \
        || ok "没有误报网卡失败（线是好的）"
else
    echo "  [跳过] 这台机器 en0 没有地址，1b 跳过"
fi

echo "== 2. 失败后 kill worker 并不能让在途分片停手（用户干等）=="
# 父进程检出 404 后建 stop 并 kill worker，但 bash 会把发给"正在等前台子命令
# 的 shell"的 SIGTERM 推迟到该子命令结束；worker 前台跑的是 \$(curl ...)。
# 于是：在途分片整片下完（或等到 --speed-time 20s 才中止），父进程卡在 wait，
# 用户看到的是失败后长时间完全没有输出。桩让另一个分片"头发完就再也不给
# body"，curl 要 20 秒才被 speed-time 中止。
S="$(date +%s)"
bash smartroute.sh fetch "http://127.0.0.1:$PORT/hang404/8000000/2000000" \
     -o "$T/dl.bin" -n 4 --no-balance-check > "$T/out" 2>&1
E="$(date +%s)"
WAIT=$(( E - S ))
grep -q "HTTP 错误：404" "$T/out" && ok "404 确实被报出来了" || miss "没报 404"
[ "$WAIT" -le 5 ] && ok "失败检出后 ${WAIT}s 就收手（在途分片被直接杀掉）" \
    || miss "白等了 ${WAIT}s——在途分片没被 kill 停住"

echo "== 3. 扩连阈值数的是「在途分片」，注释写的是「已下完/完成数」=="
# 注释（3353-3359）说"每当下完的分片数达到阈值就加一个""每个 worker 平均
# 至少要完整下完一片才允许再加人"。代码（3418）数的是 \$T/p* 文件个数——
# 而 curl 一收到第一个 body 字节就建这个文件，所以"刚开始下"就算"下完了"。
# 慢速链路（trickle：每片 4s，但数据持续在流）上，第 3 个 worker 在第 0.45s
# 就被拉起来，而此时一片都还没下完。
run_fetch /trickle/32000000/4000 8
_first_done="$(awk '/DONE/{print $1; exit}' "$T/hits.log")"
_third_seg="$(awk '/SEG/&&/seq=3/{print $1; exit}' "$T/hits.log")"
grep -q "自适应扩连：从 2 条逐步加到" "$T/out" && ok "触发了扩连（$(grep -o '逐步加到 [0-9]* 条' "$T/out")）" \
    || miss "没有扩连"
# 阈值必须数"已完成"而不是"在途"：第 3 个 worker 不许早于第一片完成
# （hits.log 由桩写，字段与既有断言同一套：SEG/DONE + 时间戳）
_T3="$(awk '/SEG/&&/seq=3/{print $1; exit}' "$T/hits.log" 2>/dev/null)"
_D1="$(awk '/DONE/{print $1; exit}' "$T/hits.log" 2>/dev/null)"
if [ -n "$_T3" ] && [ -n "$_D1" ]; then
    # 时间戳是小数（桩用 python time.time()），[ -gt ] 会报 integer expression
    # expected，必须用 awk 比
    awk -v a="$_T3" -v b="$_D1" 'BEGIN{exit !(a+0 > b+0)}' \
        && ok "第 3 个 worker 出现在第一片完成之后（阈值数的是完成数）" \
        || miss "第 3 个 worker 早于第一片完成（零片完成就加人）"
else
    miss "桩日志里找不到 SEG/DONE 记录，无法判定扩连时机"
fi
# 这段是同一件事的第二种表述（用 run_fetch 自己采的两个时间戳，而不是我上面
# 重新 awk 出来的），保留它但把方向反过来：零片完成就加人现在是**失败**。
if [ -n "$_first_done" ] && [ -n "$_third_seg" ]; then
    if awk -v a="$_third_seg" -v b="$_first_done" 'BEGIN{exit !(a<b)}'; then
        miss "第 3 个 worker 在 $(awk -v a="$_third_seg" 'BEGIN{printf "%.2f", a}')s 就被拉起，而第一片要到 $(awk -v a="$_first_done" 'BEGIN{printf "%.2f", a}')s 才下完（零片完成就加人）"
    else
        ok "第 3 个 worker 晚于第一片完成（$(awk -v a="$_third_seg" 'BEGIN{printf "%.2f", a}')s > $(awk -v a="$_first_done" 'BEGIN{printf "%.2f", a}')s）"
    fi
fi

echo "== 4. ratelimited 是全局闩锁，却被任一 worker 的成功清掉 =="
# 注释（3240-3242/3399-3401）说撞到 429 就留标记、父进程看到就不再往上加
# worker。但 3231 行在**任何**分片成功时都 rm 掉这个全局标记——多 worker 下
# 几乎必然有别的 worker 在 1s 退避窗口里成功，于是标记活了 20ms 就被删，
# 父进程 0.2s 一次的轮询基本不可能看见它。
# A/B：同一个持续 429 的慢服务端，原版 vs 删掉那行 rm 的版本。
sed 's|rm -f "$d/ratelimited" 2>/dev/null|: # 审计补丁：不清限流标记|' \
    smartroute.sh > "$T/sr_fix.sh"
for V in orig fix; do
    : > "$T/hits.log"
    SC=smartroute.sh; [ "$V" = fix ] && SC="$T/sr_fix.sh"
    bash "$SC" fetch "http://127.0.0.1:$PORT/trickle429/32000000/2000/3" \
         -o "$T/dl_$V.bin" -n 8 --no-balance-check > "$T/out_$V" 2>&1
    eval "_${V}_conns=$(grep -o '逐步加到 [0-9]*' "$T/out_$V" | grep -o '[0-9]*' | head -1)"
    eval "_${V}_429=$(grep -c 'len=12' "$T/hits.log")"
done
echo "  原版（会清标记）: 扩到 ${_orig_conns:-2} 条, 服务端回了 ${_orig_429} 个 429"
echo "  补丁版（不清标记）: 扩到 ${_fix_conns:-2} 条, 服务端回了 ${_fix_429} 个 429"
# 反转后：原版（现在的代码）不该比"限流就冻结"的版本起更多连接——
# 也就是说限流闩锁必须真的生效。
[ "${_orig_conns:-2}" -gt "${_fix_conns:-2}" ] \
    && miss "持续 429 下仍多起了 $(( _orig_conns - _fix_conns )) 条连接（闩锁没生效）" \
    || ok "限流闩锁生效（持续 429 时不加连接：${_orig_conns} vs ${_fix_conns}）"

echo "== 5. 内容回读校验在参照下载失败时静默跳过，输出照样说「完成」=="
# 3614 行的 if curl ... && [ -f "\$_vtmp" ]：参照下载一旦非 0 退出（限流、
# 抖动、超时），这一段就被跳过，而末尾没有任何提示。用户以为内容被验过了。
run_fetch /tail429/8000000/6 2
_n429="$(grep -c TAIL429 "$T/hits.log")"
[ "$_n429" -ge 1 ] && ok "内容校验的 ${_n429} 个重下请求全部撞到 429（curl 非 0 退出，校验被跳过）" \
    || miss "校验请求没有失败"
grep -q "完成:" "$T/out" && ok "仍报完成（文件本身是对的）" || miss "没有报完成"
# 关键：跳过校验必须说出来。以前静默跳过，用户以为内容被验过了。
grep -q "内容校验跳过" "$T/out" && ok "明说了有几段内容校验没做（不假装验过）" \
    || miss "内容校验被跳过却一声不吭——用户在依赖一个没发生的保证"
[ "$(wc -c < "$T/dl.bin" | tr -d ' ')" = "8000000" ] \
    && echo "  （文件本身是对的——问题只在于"验过了"这件事是假的）" || echo "  （文件大小不对，另一回事）"

echo ""
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

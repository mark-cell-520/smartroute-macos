#!/bin/bash
# 多连接下载：让两条线一起扛一个文件
#
# 背景：用户要"两个网络一起跑一个数据"。IP 路由层面做不到——pf 按连接
# 选路，一个 TCP 连接从头到尾只用一条线；一条流跨两条线需要 MPTCP，
# macOS 不支持。但"一个文件"可以拆：HTTP Range 把文件切成多段，每段一条
# 独立连接，配合 pf 轮询分摊到两个接口，再按顺序拼回。
#
# 运行: bash tests/mock_fetch.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_fetch.XXXXXX)"
mkdir -p "$T/bin" "$T/state" "$T/lock"
trap 'rm -rf "$T"' EXIT
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"

# netstat 替身：列位 Name(1) Mtu(2) Network(3) Address(4) Ipkts(5) Ierrs(6)
# Ibytes(7) Opkts(8) Oerrs(9) Obytes(10) Coll(11)
cat > "$T/bin/netstat" <<'EOF'
#!/bin/bash
# 必须带表头行：_if_bytes 用 awk 'NR==2' 取第一条数据行，
# 和真 netstat 的输出结构一致。少了表头会让 NR==2 落空、返回空。
[ "${1:-}" = "-i" ] || exit 0
echo "Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll"
for a in "$@"; do case "$a" in en*) D="$a";; esac; done
case "$D" in
    en0) echo "en0        1500  <Link#7>    c8:80:6d:42:e8:43 1000 0 5000000 900 0 3000000 0" ;;
    en1) echo "en1        1500  <Link#16>   8e:ec:2d:19:94:1e 2000 0 9000000 1800 0 7000000 0" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$T/bin/netstat"
# 注意：不能把 stderr 丢到 /dev/null——die 的用法提示全在 stderr，
# 丢了以后"参数校验"这几条断言会全假失败（最早就是这么错的）。
ev() { bash -c ". '$T/sr.sh'; trap - EXIT INT TERM HUP
        export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        export STATE_FILE='$T/state/st' LOCK_DIR='$T/lock' PF_ANCHOR_FILE='$T/none'
        $1" 2>&1; }

echo "== 1. 入口与用法 =="
grep -q 'fetch|dl)       cmd_fetch' smartroute.sh && ok "fetch 子命令已注册" || bad "没注册 fetch"
ev 'cmd_fetch --help' | grep -q "smartroute fetch <URL>" \
    && ok "--help 有用法" || bad "--help 没用法"
ev 'cmd_fetch' 2>&1 | grep -q "用法: smartroute fetch" \
    && ok "不给 URL 时报用法" || bad "不给 URL 时没报用法"
ev 'cmd_fetch http://x -n abc' 2>&1 | grep -q "连接数必须是正整数" \
    && ok "连接数非数字被拒" || bad "连接数没校验"
ev 'cmd_fetch http://x -n 0' 2>&1 | grep -q "连接数至少为 1" \
    && ok "连接数 0 被拒" || bad "连接数 0 没被拒"
ev 'cmd_fetch http://x http://y' 2>&1 | grep -q "只接受一个 URL" \
    && ok "多个 URL 被拒" || bad "多个 URL 没被拒"

echo "== 2. fmt_bytes 字节格式化 =="
[ "$(ev 'fmt_bytes 0')" = "0 B" ] && ok "0 -> 0 B" || bad "0 格式化错: $(ev 'fmt_bytes 0')"
[ "$(ev 'fmt_bytes 512')" = "512 B" ] && ok "512 -> 512 B" || bad "512 格式化错"
[ "$(ev 'fmt_bytes 2048')" = "2.0 KB" ] && ok "2048 -> 2.0 KB" || bad "2048 格式化错"
[ "$(ev 'fmt_bytes 5242880')" = "5.0 MB" ] && ok "5MiB -> 5.0 MB" || bad "5MiB 格式化错"
ev 'fmt_bytes 1500000000' | grep -q "GB" && ok "大文件用 GB" || bad "大文件没用 GB"

echo "== 3. _if_bytes 取对列 =="
# Ibytes 是第 7 列、Obytes 是第 10 列。取错列会算出完全无关的数字，
# 而流量分摊报告全建立在它上面——错了用户就被误导。
[ "$(ev '_if_bytes en0')" = "8000000" ] && ok "en0: 5000000+3000000=8000000" \
    || bad "en0 列取错: $(ev '_if_bytes en0')"
[ "$(ev '_if_bytes en1')" = "16000000" ] && ok "en1: 9000000+7000000=16000000" \
    || bad "en1 列取错: $(ev '_if_bytes en1')"
[ -z "$(ev '_if_bytes en9')" ] && ok "不存在的接口输出空（不是 0）" \
    || bad "不存在的接口应有空输出"

echo "== 4. Range 探测：三种办法都在真实 CDN 上失败过 =="
# 实测记录（都在 jsdelivr/Cloudflare 上发生过）：
#   · 普通 HEAD 有时压根不返回 Content-Length（HTTP/2 + 分块）
#   · --range 0-0 返回 206 却不带 Content-Range，只有 content-length: 1
#   · --range 999999999-（越界）规范要求 416 + Content-Range: */N，
#     且 body 为 0；但它和 HEAD 对同一 URL 会给出不同大小
#     （CDN 按请求返回不同压缩变体），信它就会切出错文件。
# 所以 HEAD 优先、越界探针兜底，最后由下载时字节数校验裁决。
grep -q "range 999999999-" smartroute.sh \
    && ok "用越界范围探测（规范强制带 Content-Range）" || bad "没有越界探测"
grep -q 'probe_code" = "416"' smartroute.sh \
    && ok "按 416 判定支持 Range" || bad "没有按 416 判定"
grep -q "head_size" smartroute.sh \
    && ok "HEAD 优先取大小" || bad "没有 HEAD 优先"
grep -q "两个大小" smartroute.sh \
    && ok "两个来源不一致时会告知用户" || bad "大小冲突不告知"
# Content-Range 的值形如 "bytes */31402"，$2 是单位、$3 才是值。
# 用 $2 会永远拿不到大小，于是每次都退化成单连接——极难查。
grep -q 'sub(/\^\[^:\]\*:\[\[:space:\]\]\*/,"",line)' smartroute.sh \
    && ok "取冒号后全部内容，没用 $2（$2 是单位 bytes）" || bad "还在用 $2 取 Content-Range"
grep -q 'sub(/\\r\$/,"",line)' smartroute.sh \
    && ok "去掉行尾 CR（curl -D - 输出 CRLF）" || bad "没去 CR"
# 只查"有没有拿它当判据"：判据必须是真实 206 返回码
grep -q 'accept_ranges' smartroute.sh \
    && bad "还在用 accept_ranges 变量做判据（已证明不可靠）" || ok "不拿 Accept-Ranges 头做判据"

echo "== 5. 分片必须重试 =="
# 这个工具的用途就是同时开多条连接，偶发超时从 rare 变成几乎每次都有。
# 不重试的话 8 段挂 1 段整个下载就废了。实测 -n 8 首轮会撞 Recv failure。
grep -q "for try in 1 2 3" smartroute.sh \
    && ok "每片重试 3 次" || bad "没有重试"
grep -q "已重试 3 次" smartroute.sh \
    && ok "重试耗尽有明确提示" || bad "重试耗尽没提示"

echo "== 6. 流量分摊不能伪造证据 =="
# 实测：没开分流时 en0 也有 247 字节（TCP 握手/DNS），不是有效载荷。
# 按"非零即算"会打出"✅ 两条线都在扛"，而实际 99% 在另一条线上。
# 伪造证据比不报更糟——用户照着错误结论排查会被带偏。
echo "== 5b. 工作队列：不能固定切分 =="
# 固定切分由最慢的那一段决定总时长。本机 100M 有线配 432M Wi-Fi，
# -n 8 均分 4/4：有线那 4 段是瓶颈，Wi-Fi 早早下完就闲着，聚合白做。
# 工作队列让快的线自然多认领分片，不需要知道两条线各多快。
grep -q "_claim_chunk" smartroute.sh \
    && ok "有认领机制（工作队列）" || bad "还是固定切分"
grep -q "_fetch_worker" smartroute.sh \
    && ok "worker 认领-下载循环" || bad "没有 worker 循环"
grep -q 'mkdir "\$q/c\$i"' smartroute.sh \
    && ok "用 mkdir 原子认领（无锁）" || bad "认领不是原子的"
grep -q "total_chunks=128" smartroute.sh \
    && ok "目标 128 片以上（细粒度才能自平衡）" || bad "片数太少，粗粒度无法自平衡"

echo "== 5c. 失败必须说清原因 =="
# "下载失败"会让用户以为是网络问题；实测多数是服务端 Range 不一致，
# 那种情况该换源而不是降 -n。笼统一句等于让用户瞎猜。
grep -q "分片大小与请求不符" smartroute.sh \
    && ok "大小不符有专门提示" || bad "大小不符没有专门提示"
grep -q "请换一个源，或用单连接下载" smartroute.sh \
    && ok "给出换源建议" || bad "没给换源建议"
# read 的目标不能是 _：bash 里 _ 是特殊变量，会被覆盖，读出来是空的
grep -q 'read -r _fidx _fwant _fgot' smartroute.sh \
    && ok "read 用了普通变量名（没用 _）" || bad "read 目标用了 _"

grep -q "_min_pct=5" smartroute.sh \
    && ok "有 5% 有效分担阈值" || bad "没有阈值，会把 247 字节当成在扛"
grep -q 'pct_eth" -lt "$_min_pct"' smartroute.sh \
    && ok "低于阈值判为未生效" || bad "没有按阈值判定"
grep -q "伪造证据比不报更糟" smartroute.sh \
    && ok "注释写清了为什么不能按非零算" || bad "缺关键注释"
# 负增量（计数器回绕/刚重连）必须归零，不能报出负字节
grep -q 'd_eth" -lt 0 \] && d_eth=0' smartroute.sh \
    && ok "负增量归零" || bad "负增量没处理"

echo "== 7. RETURN trap 只在 cmd_fetch 返回时触发（实测锁定的语义）=="
# bash 的 RETURN trap 只被设置它的那个函数触发，不继承给被调函数，
# 所以 _fetch_seg/_fetch_worker 返回时不会误删临时目录。
# 但这个结论依赖"助手函数在 trap 设置之后定义"——一旦把助手外移，
# trap 就会在助手返回时删掉 $T、下载全线失败。这里用同样的函数结构锁定。
cat > "$T/trapcase.sh" <<'CASE'
T="$1"
fetch_like() {
    trap 'rm -rf "$T"' RETURN INT TERM HUP
    _seg() { echo x > "$T/p0"; return 0; }
    _worker() { _seg; echo "worker T: $([ -d "$T" ] && echo yes || echo no)"; }
    _worker &
    wait $! || echo "worker 失败"
    echo "wait T: $([ -d "$T" ] && echo yes || echo no)"
}
fetch_like
echo "after T: $([ -d "$T" ] && echo yes || echo no)"
CASE
TD="$(mktemp -d /tmp/sr_trap.XXXXXX)"
tr_out="$(bash "$T/trapcase.sh" "$TD" 2>&1)"
echo "$tr_out" | grep -q "worker T: yes" \
    && ok "助手函数返回不触发 RETURN trap" || bad "助手返回就删了临时目录"
echo "$tr_out" | grep -q "wait T: yes" \
    && ok "wait 之后临时目录仍在（下载能跑完）" || bad "wait 前临时目录就没了"
echo "$tr_out" | grep -q "after T: no" \
    && ok "函数返回时才清理" || bad "没有清理，/tmp 会堆积"
rm -rf "$TD"
grep -q "RETURN trap 只在\*\*设置它的那个函数\*\*返回时触发" smartroute.sh \
    && ok "注释写清了 trap 语义和外移助手函数的后果" || bad "缺关键注释"
grep -q "要外移助手函数的话" smartroute.sh \
    && ok "说明了外移助手函数时该怎么改" || bad "没说外移时的改法"

echo "== 8. 吞吐单位必须自洽（修 8 倍虚高）=="
# size 是字节、t_dur 是秒 → 字节/秒；fmt_bps 入参也是字节/秒（内部 *8）。
# 以前先 *8 成 bit/s 再交给 fmt_bps，等于乘两次 8：85.5KB/4s 报 1.4 Mbps，
# 真实值 0.175 Mbps。而且拿 bit/s 和字节/秒的 _fast 比大小，阈值判断也错。
grep -q 'bps=$(( size \* 1000 / t_dur ))' smartroute.sh \
    && ok "bps 是字节/秒（没先 *8）" || bad "bps 单位错"
grep -q 'bps=$(( size \* 8 / t_dur ))' smartroute.sh \
    && bad "还在乘两次 8" || ok "没有重复乘 8"
grep -q '_metric_fresh "speed_\$ACTIVE_ETH_DEV" "\$SPEED_RECHECK"' smartroute.sh \
    && ok "结论前检查测速缓存是否过期" || bad "拿过期测速值下结论"
grep -q "无法判断并发是否带来收益" smartroute.sh \
    && ok "缓存过期时明说无法判断（不下错结论）" || bad "过期时仍下结论"
grep -q 't_ns_now="$(date +%s%N)"' smartroute.sh \
    && ok "用纳秒计时（小文件吞吐不被低估）" || bad "还是整秒计时"

echo "== 9. HTTP 错误不能被误诊成 Range 不兼容 =="
# 以前 _fetch_seg 没加 --fail：404 时 curl 返回 0、错误页写进分片，
# 走到"字节数不符"分支，重试 3 次后报"服务端 Range 行为不一致"，
# 用户会跑去换源，而真正原因只是 URL 写错。
grep -q 'curl -sS -L --fail --max-time 600' smartroute.sh \
    && ok "分片下载带 --fail" || bad "分片下载没带 --fail"
grep -q "httperr_" smartroute.sh \
    && ok "HTTP 错误单独记录" || bad "没有单独记录 HTTP 错误"
grep -q "请先确认这个 URL 用浏览器能打开" smartroute.sh \
    && ok "HTTP 错误给出可操作建议" || bad "HTTP 错误无可操作建议"
[ "$(grep -c 'curl -L --fail --progress-bar' smartroute.sh)" -ge 2 ] \
    && ok "两处回退下载都带 --fail" || bad "回退下载没带 --fail"
grep -q "这个 URL 打不开" smartroute.sh \
    && ok "探测阶段区分 HTTP 错误和不支持 Range" || bad "HTTP 错误被说成不支持 Range"

echo "== 10. 权重为 0 会让一条线静默饿死 =="
# write_pf_rules 不校验 $7/$8：传 0 时那一侧 while 一次都不跑，
# route-to 里没有它的条目 → 一条线拿到 0 个连接，而函数返回 0、无警告。
grep -q "权重必须落在 \[1,8\]" smartroute.sh \
    && ok "有权重校验" || bad "没有权重校验"
gen_w() {   # $1=wA $2=wB
    bash -c ". '$T/sr.sh'; trap - EXIT INT TERM HUP
        export PATH='/usr/bin:/bin:/usr/sbin:/sbin'
        export LOCK_DIR='$T/lock' STATE_FILE='$T/state/st' PF_ANCHOR_FILE='$T/w.conf' PF_ANCHOR=a
        svc_router() { echo 192.168.1.1; }; other_nets() { echo; }
        dev_subnet() { echo 192.168.1.0/24; }; eth_wifi_same_gateway() { return 0; }
        pfctl() { return 0; }; pf_enabled() { return 1; }
        write_pf_rules en0 192.168.1.1 en1 192.168.1.1 '' '' '$1' '$2' >/dev/null 2>&1
        a=\$(grep -o -F '(\$ext1 \$gw1)' '$T/w.conf' | wc -l | tr -d ' ')
        b=\$(grep -o -F '(\$ext2 \$gw2)' '$T/w.conf' | wc -l | tr -d ' ')
        echo \"\$a \$b\"" 2>/dev/null
}
[ "$(gen_w 0 4)" = "1 4" ] && ok "wA=0 被夹到 1（不饿死 en0）" || bad "wA=0 仍饿死 en0: $(gen_w 0 4)"
[ "$(gen_w abc 4)" = "1 4" ] && ok "wA 非数字被夹到 1" || bad "非数字权重放行: $(gen_w abc 4)"
[ "$(gen_w 99 99)" = "8 8" ] && ok "过大权重被夹到 8" || bad "过大权重放行: $(gen_w 99 99)"
[ "$(gen_w 1 4)" = "1 4" ] && ok "正常权重不受影响" || bad "正常权重被改坏: $(gen_w 1 4)"

echo "== 11. 分摊报告要说明含无关流量 =="
# 窗口内测的是接口全部字节（其他 app、DNS、系统更新）。总量远超文件大小时
# 百分比被污染，以前不提示，用户对不上还以为工具算错。
grep -q "远大于本次下载的" smartroute.sh \
    && ok "总量异常时明确提示含其他流量" || bad "没有无关流量提示"
grep -q "要精确测量，请关掉其他下载/同步类程序后重试" smartroute.sh \
    && ok "给出精确测量的办法" || bad "没给办法"

echo "== 12. -n 上限与合并引号 =="
# 无上限时 -n 1000 起 1000 个 curl：不会更快，还会拖死机器、
# 触发系统并发限制，最后表现成"下载失败"。
grep -q "连接数上限 64" smartroute.sh \
    && ok "-n 有上限 64" || bad "-n 无上限"
grep -qF '_catlist="$_catlist \"$T/p$_i\""' smartroute.sh \
    && ok "合并时分片路径加引号" || bad "合并路径未加引号"
grep -q 'eval "cat \$_catlist"' smartroute.sh \
    && ok "用 eval 拼装（片数多也不触 ARG_MAX）" || bad "合并方式有风险"

echo "== 13. 小文件 worker 空转要说清 =="
# 片数少于 worker 数时多余的 worker 直接退出。不说清楚的话，
# 用户看到"8 个 worker"会以为有 8 条连接在跑，实际可能只有 1 条。
grep -q "个连接里有" smartroute.sh \
    && ok "说明有多少连接空转" || bad "没说 worker 空转"
grep -q "小文件切太细反而更慢，这是有意的" smartroute.sh \
    && ok "说明为什么小文件不切细" || bad "没解释小文件行为"

echo ""
echo "结果: $((PASS - FAIL)) 通过, $FAIL 失败"

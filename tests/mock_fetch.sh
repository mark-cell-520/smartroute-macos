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

echo "== 4. Range 探测必须真发请求，不能只信头 =="
# 实测 speed.cloudflare.com 不返回 Accept-Ranges 头，却也不认 Range
# （请求 0-99 照样给全量）。只信头会把"不支持"误判成"支持"，
# 然后切段、拼出一个错文件。所以必须看真实返回码是不是 206。
grep -q "请求 0-63 返回" smartroute.sh \
    && ok "用真实 Range 请求的结果说话" || bad "没有真发 Range 请求"
grep -q 'probe_code" != "206"' smartroute.sh \
    && ok "只接受 206" || bad "没有校验 206"
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
grep -q "_min_pct=5" smartroute.sh \
    && ok "有 5% 有效分担阈值" || bad "没有阈值，会把 247 字节当成在扛"
grep -q 'pct_eth" -lt "$_min_pct"' smartroute.sh \
    && ok "低于阈值判为未生效" || bad "没有按阈值判定"
grep -q "伪造证据比不报更糟" smartroute.sh \
    && ok "注释写清了为什么不能按非零算" || bad "缺关键注释"
# 负增量（计数器回绕/刚重连）必须归零，不能报出负字节
grep -q 'd_eth" -lt 0 \] && d_eth=0' smartroute.sh \
    && ok "负增量归零" || bad "负增量没处理"

echo ""
echo "结果: $((PASS - FAIL)) 通过, $FAIL 失败"

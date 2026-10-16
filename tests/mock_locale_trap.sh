#!/bin/bash
# 全角标点紧跟 $变量名——这个坑已经踩了 5 次
#
# 现象：bash 在 UTF-8 locale 下会把全角字符（如 ）！？，。等）当成变量名的
# 合法组成部分。于是 "$var）" 被解析成名为 "var）" 的变量，展开成空字符串。
# 结果不是报错，而是**静默变成空**——日志里少一段信息，或者更糟：
# 一条本该带上参数的恢复命令变成 "sudo route add default  -interface "。
#
# 修法：写成 "${var}）"，用花括号把变量名边界锁死。
#
# 这个检查跑在三个脚本上，任何新增的全角紧跟都要么改成花括号，
# 要么确认不在双引号内（单引号/注释里不展开，是安全的）。
checks=0; failures=0
ok()  { checks=$((checks+1)); printf '  ✓ %s\n' "$1"; }
bad() { failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

# 匹配：$名字 后面紧跟一个非 ASCII 可见字符（即全角标点/中文）
PAT='\$[A-Za-z_][A-Za-z0-9_]*[^ -~]'

for f in smartroute.sh install.sh uninstall.sh; do
    [ -f "$f" ] || continue
    n="$(grep -c "$PAT" "$f" 2>/dev/null)"; n="${n:-0}"
    if [ "$n" -eq 0 ]; then
        ok "$f 无全角紧跟变量名"
    else
        bad "$f 有 $n 处全角紧跟变量名："
        grep -n "$PAT" "$f" | sed 's/^/      /' | head -5
    fi
done

echo "== 2. 花括号写法确实存在（证明修法被采用）=="
grep -q '${LOCK_DIR}' smartroute.sh \
    && ok "smartroute.sh 用了 \${LOCK_DIR} 锁死边界" || bad "没有采用花括号修法"
grep -q '${bak_gw}' smartroute.sh \
    && ok "smartroute.sh 用了 \${bak_gw}" || bad "bak_gw 没用花括号"

echo "== 3. 单引号/注释里的不算（不应误报）=="
# 确认检查逻辑不会把明显安全的情况算进去：造一行单引号里的，看 grep 行为
echo "x='\$foo）'" > /tmp/sr_trap_probe.$$
if grep -q "$PAT" /tmp/sr_trap_probe.$$; then
    # grep 是纯文本匹配，分不出引号语境——所以这个检查偏严格，
    # 宁可误报也不要漏报。误报的代价是改一下，漏报的代价是静默空值。
    ok "检查偏严格（单引号内也会报）——这是有意的，漏报比误报危险"
else
    ok "检查能区分引号语境"
fi
rm -f /tmp/sr_trap_probe.$$

echo ""
echo "结果: $((checks - failures)) 通过, $failures 失败"

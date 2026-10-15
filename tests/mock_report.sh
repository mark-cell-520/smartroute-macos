#!/bin/bash
# 测试 smartroute report —— 一键诊断报告
#
# 报告是给用户"贴给别人排查"用的，所以有两个硬要求：
#   1. 九个区段一个都不能少（少一段就意味着排查时缺关键信息）
#   2. 必须是纯文本：不能带 ANSI 颜色码，否则贴到网页/Issue 里全是乱码
#
# 运行: bash tests/mock_report.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

OUT="$(bash smartroute.sh report 2>&1)"

echo "=== 1. 九个区段齐全 ==="
for sec in "smartroute 诊断报告" "硬件接口" "接口地址" "路由表" "pf 状态" \
           "配置" "守护进程状态" "状态文件" "最近日志" "双网并发状态" "报告结束"; do
    if printf '%s' "$OUT" | grep -q "$sec"; then ok "含区段：$sec"; else bad "缺区段：$sec"; fi
done

echo "=== 2. 纯文本，无 ANSI 颜色码 ==="
# 颜色码长这样：ESC[32m。report 是给人复制粘贴的，混进颜色码就成了乱码
if printf '%s' "$OUT" | grep -q $'\033'; then
    bad "输出里含 ANSI 转义符（贴出去会变乱码）"
    printf '%s' "$OUT" | grep -n $'\033' | head -3
else
    ok "无 ANSI 颜色码"
fi

echo "=== 3. 基本信息 ==="
printf '%s' "$OUT" | grep -q "运行身份:" && ok "记录了运行身份（root/普通用户）" || bad "缺运行身份"
printf '%s' "$OUT" | grep -q "系统:"      && ok "记录了系统版本" || bad "缺系统版本"
printf '%s' "$OUT" | grep -q "架构:"      && ok "记录了架构" || bad "缺架构"

echo "=== 4. 隐私提示（报告会被分享，必须说明） ==="
printf '%s' "$OUT" | grep -q "可以放心分享" && ok "有隐私说明" || bad "缺隐私说明"
printf '%s' "$OUT" | grep -qi "密码"        && ok "明确说不含密码" || bad "没提密码"

echo "=== 5. 路由表只保留 IPv4（否则 utun/fe80 把报告撑爆） ==="
v6lines=$(printf '%s' "$OUT" | sed -n '/路由表/,/pf 状态/p' | grep -c 'fe80\|ff0[02]::')
if [ "$v6lines" -eq 0 ]; then ok "路由表已过滤 IPv6"; else bad "路由表残留 $v6lines 行 IPv6"; fi

echo "=== 6. 非 root 也能跑（不能因为没权限就报错退出） ==="
RC=0
bash smartroute.sh report >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ]; then ok "非 root 下正常退出（退出码 0）"; else bad "非 root 下退出码 $RC"; fi
# 非 root 时 pf/launchctl 段应该明确说"跳过"而不是静默空白
if printf '%s' "$OUT" | grep -q "非 root，跳过"; then ok "无权限段落有明确提示"; else bad "无权限段落没提示"; fi

echo "=== 7. 输出可重定向（report 的典型用法） ==="
T=$(mktemp /tmp/sr_report.XXXX.txt)
bash smartroute.sh report > "$T" 2>/dev/null
if [ -s "$T" ]; then
    ok "可重定向到文件（$(wc -l < "$T" | tr -d ' ') 行）"
else
    bad "重定向后文件为空"
fi
rm -f "$T"

echo "=== 8. usage 里登记了这个命令 ==="
bash smartroute.sh --help 2>&1 | grep -q "report" && ok "--help 里有 report" || bad "--help 缺 report"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

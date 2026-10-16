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
           "配置" "守护进程状态" "状态文件" "最近日志" "双网并发状态" "Wi-Fi 网络与故障转移" "报告结束"; do
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

echo "=== 8. Wi-Fi 区段内容 ==="
printf '%s' "$OUT" | grep -q "已保存的网络" && ok "列出了已保存网络" || bad "缺已保存网络"
printf '%s' "$OUT" | grep -q "自动故障转移: WIFI_FAILOVER=" && ok "显示故障转移开关状态" || bad "缺故障转移状态"
printf '%s' "$OUT" | grep -q "优先列表=" && ok "显示优先列表" || bad "缺优先列表"

echo "=== 9. usage 里登记了这个命令 ==="
bash smartroute.sh --help 2>&1 | grep -q "report" && ok "--help 里有 report" || bad "--help 缺 report"

echo "=== 11. doctor：同网关要给出可操作的建议 ==="
# 实测发现本机网线和 Wi-Fi 网关都是 192.168.1.1（同一台路由器）。
# 原来 doctor 只提示"同网段"，建议是"修改路由器 LAN 网段"——大多数人
# 根本改不了路由器，等于没建议。同网关真正该做的是关掉双网并发。
DOC="$(bash smartroute.sh doctor 2>&1)"
printf '%s' "$DOC" | grep -q "同网段" && ok "仍提示同网段" || bad "丢了同网段提示"
if printf '%s' "$DOC" | grep -q "网关相同"; then
    ok "同网关时明确说出来"
    printf '%s' "$DOC" | grep -q "BALANCE=1）不会有任何带宽收益" \
        && ok "说明为什么没收益（一条 WAN 两个入口）" || bad "没说清为什么"
    printf '%s' "$DOC" | grep -q "建议关闭双网并发" \
        && ok "给出可操作建议（关并发）" || bad "没有可操作建议"
    printf '%s' "$DOC" | grep -q "balance off" \
        && ok "建议里带具体命令" || bad "建议里没有命令"
else
    echo "  （本机不同网关，跳过同网关相关断言）"
fi
printf '%s' "$DOC" | grep -q "建议：" && ok "有建议区" || bad "没有建议区"

echo "=== 12. smartroute log：行数参数的两种写法都要能用 ==="
# 出过真 bug：cmd_log 只认 `log 40`，而 `log --lines 40` 会把 "--lines"
# 当行数传给 tail，报 "tail: illegal offset -- --lines"。
# 人看 --lines 更自然，很容易踩到；App 当初也因此改成自己直接 tail。
_l() { bash smartroute.sh log "$@" 2>&1; }
_n() { bash smartroute.sh log "$@" 2>/dev/null | wc -l | tr -d ' '; }
_l | grep -q "illegal offset" && bad "默认调用报 tail 错误" || ok "默认调用正常"
[ "$(_n)" = "50" ] && ok "默认 50 行" || bad "默认得到 $(_n) 行"
[ "$(_n 5)" = "5" ] && ok "log 5 取 5 行" || bad "log 5 得到 $(_n 5) 行"
[ "$(_n --lines 5)" = "5" ] && ok "log --lines 5 取 5 行" || bad "--lines 5 得到 $(_n --lines 5) 行"
[ "$(_n -n 5)" = "5" ] && ok "log -n 5 也认" || bad "-n 5 得到 $(_n -n 5) 行"
# 垃圾/越界值要回落默认值，而不是把 "--lines"、"abc"、"0" 传给 tail
for bad_arg in "--lines" "abc" "0" "-3"; do
    if _l "$bad_arg" | grep -qE "illegal offset|用法"; then
        bad "log $bad_arg 报错（应回落默认值）"
    else
        ok "log $bad_arg 安全回落（$(_n "$bad_arg") 行）"
    fi
done
bash smartroute.sh --help 2>&1 | grep -q "log \[N\]" && ok "--help 说明两种写法" || bad "--help 未说明"

echo "=== 13. 写不进配置时必须报错，不能假成功 ==="
# 这一类 bug 出过三次：balance off / wifi auto on|off / config set
# 都是"打印已成功，但配置文件一个字都没改"。共同点是忽略了
# conf_set_auto 的返回值，而 /Users/Shared/smartroute.conf 属 root 时
# 普通用户根本写不进去——用户以为设好了，守护进程完全不按这个来。
# 判据：非 root 且配置不可写时，命令必须返回非 0，且 stderr 有说明。
if [ -w /Users/Shared/smartroute.conf ] || [ -w /Users/Shared ]; then
    echo "  （本机配置可写，跳过——这类断言要在配置属 root 的机器上才生效）"
else
    for c in "wifi auto on" "wifi auto off" "config set BALANCE 1" "balance off"; do
        out="$(bash smartroute.sh $c 2>&1)"; rc=$?
        [ "$rc" -ne 0 ] && ok "$c 写不进时返回非 0" || bad "$c 假成功（rc=0）"
        printf '%s' "$out" | grep -q "root" && ok "$c 提示了 root 相关原因" || bad "$c 没说明为什么失败"
    done
fi
# 但配置可写时（App 提权后）必须真的生效——不能为了防假成功而永远拒绝
if [ -w /Users/Shared/smartroute.conf ] || [ -w /Users/Shared ]; then
    before="$(grep -c '^WIFI_FAILOVER=' /Users/Shared/smartroute.conf 2>/dev/null || echo 0)"
    bash smartroute.sh wifi auto on >/dev/null 2>&1
    after="$(grep '^WIFI_FAILOVER=' /Users/Shared/smartroute.conf 2>/dev/null | head -1)"
    [ "${after#WIFI_FAILOVER=}" = "1" ] && ok "配置可写时 wifi auto on 真的写入" || bad "可写时也没写入: $after"
    bash smartroute.sh wifi auto off >/dev/null 2>&1
    after2="$(grep '^WIFI_FAILOVER=' /Users/Shared/smartroute.conf 2>/dev/null | head -1)"
    [ "${after2#WIFI_FAILOVER=}" = "0" ] && ok "wifi auto off 真的写入" || bad "off 也没写入: $after2"
fi

# 这两个不受配置权限影响，能证明 config set 真的转发给了 cmd_set
# （以前 config 完全忽略参数，只打印一遍当前配置）
out="$(bash smartroute.sh config set 不存在的KEY 1 2>&1)"; rc=$?
printf '%s' "$out" | grep -q "不支持的配置项" && ok "config set 转发到校验（拒绝未知键）" || bad "config set 没校验: $out"
out="$(bash smartroute.sh config set BALANCE 2>&1)"; rc=$?
printf '%s' "$out" | grep -q "KEY VALUE" && ok "config set 缺值时给用法" || bad "缺值没给用法: $out"
out="$(bash smartroute.sh config 乱参数 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "用法" && ok "config 带陌生参数时报用法错误" || bad "config 陌生参数被静默忽略"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

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
    # 可操作建议不能是"把用户要的功能关掉"。
    # 用户明确要的就是并发（"两个网络一起跑一个数据"），doctor 每次劝他
    # 关掉既不听诉求，也没说清什么还有效。而且"挑一个更快的接口"这个
    # 旧建议是**错的**：同网关下用 smartroute fetch 多连接下载仍能超过
    # 单连接速度——瓶颈常在单条 TCP 的拥塞控制/窗口，不在聚合链路带宽。
    # 所以现在给的建议是：用 fetch -n 4 把多个连接分摊到两个接口。
    # -n 从 16 改成 4 是实测定的：n=4 是吞吐峰值（17.6 Mbps），
    # n=16 掉到 8.0 Mbps 且 11/16 个分片失败。而且现在 -n 是上限，
    # 工具会自适应扩连，不需要用户猜一个大的数。
    printf '%s' "$DOC" | grep -q "smartroute fetch <URL> -n 4" \
        && ok "给出可操作建议（多连接下载）" || bad "没有可操作建议"
    printf '%s' "$DOC" | grep -q "smartroute fetch" \
        && ok "建议里带具体命令" || bad "建议里没有命令"
    # 必须仍然说清"为什么不增加聚合带宽"——不能因为要给希望就说谎
    printf '%s' "$DOC" | grep -q "不增加聚合带宽" \
        && ok "仍说清不增加聚合带宽（不说谎）" || bad "把限制说没了"
    # 不能再劝关功能
    printf '%s' "$DOC" | grep -q "建议关闭双网并发" \
        && bad "还在劝用户关掉他要的功能" || ok "没有劝关功能"
    printf '%s' "$DOC" | grep -q "想更快就改用" \
        && bad "还在给错的建议（挑一个更快的接口）" || ok "没有挑单接口的建议"
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
# 本文件里 $T 是 mktemp 出来的普通文件，这里要改成目录，
# 否则往 $T/xxx.sh 写会失败。
TD="$(mktemp -d /tmp/sr_report.XXXXXX)"
mkdir -p "$TD"
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$TD/sr.sh"
# 配置可写时必须真的生效——不能为了防假成功而永远拒绝。
# **必须用临时配置文件**：直接跑 `bash smartroute.sh wifi auto on` 会写真实的
# /Users/Shared/smartroute.conf，测试就变成了"跑一次回归改一次用户配置"。
# 这里 source 脚本前缀后把 USER_CONF 指到临时文件，全程不碰真实系统。
cat > "$TD/confw.sh" <<'CWEOF'
#!/bin/bash
T="$1"; act="$2"
. "$T/sr.sh"
USER_CONF="$T/fake.conf"
conf_set_auto WIFI_FAILOVER "$act"
echo "rc=$?"
grep '^WIFI_FAILOVER=' "$T/fake.conf" 2>/dev/null | head -1
CWEOF
out="$(bash "$TD/confw.sh" "$TD" 1 2>/dev/null)"
[ "$(printf '%s' "$out" | head -1)" = "rc=0" ] && ok "conf_set_auto 可写时返回 0" || bad "可写时反而失败: $out"
printf '%s' "$out" | grep -q "WIFI_FAILOVER=1" && ok "可写时真的写进去了" || bad "可写时没写入: $out"
out="$(bash "$TD/confw.sh" "$TD" 0 2>/dev/null)"
printf '%s' "$out" | grep -q "WIFI_FAILOVER=0" && ok "改成 0 也生效" || bad "改成 0 没生效: $out"
# 已有同名项时要更新而不是追加（否则配置文件里出现两行 WIFI_FAILOVER）
out="$(bash "$TD/confw.sh" "$TD" 1 2>/dev/null; bash "$TD/confw.sh" "$TD" 0 2>/dev/null | grep -c '^WIFI_FAILOVER=')"
[ "$(printf '%s' "$out" | tail -1)" = "1" ] && ok "重复设置不产生重复行" || bad "出现重复行: $out"

# 这两个不受配置权限影响，能证明 config set 真的转发给了 cmd_set
# （以前 config 完全忽略参数，只打印一遍当前配置）
out="$(bash smartroute.sh config set 不存在的KEY 1 2>&1)"; rc=$?
printf '%s' "$out" | grep -q "不支持的配置项" && ok "config set 转发到校验（拒绝未知键）" || bad "config set 没校验: $out"
out="$(bash smartroute.sh config set BALANCE 2>&1)"; rc=$?
printf '%s' "$out" | grep -q "KEY VALUE" && ok "config set 缺值时给用法" || bad "缺值没给用法: $out"
out="$(bash smartroute.sh config 乱参数 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "用法" && ok "config 带陌生参数时报用法错误" || bad "config 陌生参数被静默忽略"

cat > "$TD/evil.conf" <<'EVEOF'
MODE=latency
touch /tmp/SR_TEST_PWNED_CONF
SPEED_SWITCH_RATIO=abc
OK_N=-3
BOGUS_KEY=1
WIFI_FAILOVER=1
EVEOF
cat > "$TD/parse.sh" <<'PREOF'
#!/bin/bash
T="$1"
. "$T/sr.sh"
USER_CONF="$T/evil.conf"
conf_parse_file "$USER_CONF"
printf 'MODE=%s\n'          "$MODE"
printf 'WIFI_FAILOVER=%s\n' "$WIFI_FAILOVER"
printf 'RATIO=%s\n'         "$SPEED_SWITCH_RATIO"
printf 'OK_N=%s\n'          "$OK_N"
printf 'BOGUS=%s\n'         "${BOGUS_KEY:-UNSET}"
PREOF
cat > "$TD/notify.sh" <<'NOOF'
#!/bin/bash
T="$1"
. "$T/sr.sh"
NOTIFY=1
notify "SmartRoute" "已切换到可用 Wi-Fi：$(cat "$T/ssid.txt")"
NOOF

echo "=== 14. 用户配置必须解析而不是 source（防本地提权） ==="
# 出过真漏洞：USER_CONF=/Users/Shared/smartroute.conf 被 root 守护进程 source，
# 而 /Users/Shared 是 1777、install.sh 从不创建这个文件——
# 任何本地用户创建它就能在 20 秒内拿到 root。实测复现成功。
# 现在改成逐行解析 + 白名单 + 按 key 校验值，绝不执行文件里的代码。
rm -f /tmp/SR_TEST_PWNED_CONF
out="$(bash "$TD/parse.sh" "$TD" 2>&1)"
printf '%s' "$out" | grep -q "MODE=latency"     && ok "合法键生效（MODE）" || bad "合法键没生效: $out"
printf '%s' "$out" | grep -q "WIFI_FAILOVER=1"  && ok "合法键生效（WIFI_FAILOVER）" || bad "布尔键没生效"
printf '%s' "$out" | grep -q "RATIO=30"         && ok "非法值被拒（回落默认 30）" || bad "非法值生效了: $out"
printf '%s' "$out" | grep -q "OK_N=2"           && ok "负数被拒（回落默认 2）" || bad "负数生效了"
printf '%s' "$out" | grep -q "BOGUS=UNSET"      && ok "白名单外的键被拒" || bad "白名单外的键生效了"
[ ! -e /tmp/SR_TEST_PWNED_CONF ] && ok "配置文件里的任意代码没有执行" || bad "配置文件被 source 了，任意代码已执行"
rm -f /tmp/SR_TEST_PWNED_CONF
# 函数必须先定义再调用（bash 的硬性要求，改错过一次）
_call="$(grep -n '^conf_parse_file "\$USER_CONF"' smartroute.sh | head -1 | cut -d: -f1)"
_def="$(grep -n '^conf_parse_file() {' smartroute.sh | head -1 | cut -d: -f1)"
[ -n "$_call" ] && [ -n "$_def" ] && [ "$_call" -gt "$_def" ] \
    && ok "conf_parse_file 调用点在定义之后" || bad "调用点在定义之前（bash 会 command not found）"

echo "=== 15. notify() 必须转义 AppleScript（防恶意 Wi-Fi 名 RCE） ==="
# 出过真漏洞：$2 未转义就插进 osascript，而故障转移成功时 $2 是当前 Wi-Fi 名，
# Wi-Fi 名完全由 AP 控制。实测：不转义时恶意 SSID 能逃逸执行 do shell script
# （守护进程是 root，于是恶意 AP + 保存过该网络的受害者 = root RCE）。
rm -f /tmp/SR_TEST_PWNED_NOTIFY
printf '%s' 'foo" & (do shell script "touch /tmp/SR_TEST_PWNED_NOTIFY") & "' > "$TD/ssid.txt"
bash "$TD/notify.sh" "$TD" >/dev/null 2>&1
sleep 1
[ ! -e /tmp/SR_TEST_PWNED_NOTIFY ] && ok "恶意 SSID 的 payload 没有执行" || bad "notify 注入成功，payload 执行了"
rm -f /tmp/SR_TEST_PWNED_NOTIFY
# 转义本身要正确：先 \ 再 "（顺序反了会二次转义）。
# 用 grep 而不是精确比较——精确比较要在测试文件里再套一层引号转义，
# 很容易把期望值写错（刚才就连错两次，断言报红但功能其实是对的）。
_q() { bash -c ". '$TD/sr.sh'; as_escape '$1'" 2>/dev/null; }
printf '%s' "$(_q 'a"b')" | grep -F 'a\"b' >/dev/null && ok "双引号被转义成 \\\"" || bad "双引号没转义: $(_q 'a"b')"
printf '%s' "$(_q 'a"b')" | grep -q '^a\\"b$'      && ok "转义位置正确（行首行尾）" || bad "转义位置不对"
printf '%s' "$(_q 'a\b')" | grep -F 'a\\b' >/dev/null && ok "反斜杠被转义成 \\\\" || bad "反斜杠没转义: $(_q 'a\b')"
[ "$(_q '普通中文')" = "普通中文" ] && ok "普通内容不被破坏" || bad "普通内容被改坏了: $(_q '普通中文')"
# 正常通知不能因此坏掉
bash -c ". '$TD/sr.sh'; NOTIFY=1; notify 'T' '普通中文通知'" >/dev/null 2>&1 \
    && ok "正常通知仍然可用" || bad "正常通知坏了"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

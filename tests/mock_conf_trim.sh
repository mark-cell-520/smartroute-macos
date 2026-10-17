#!/bin/bash
# 配置解析的 trim 与返回值检查测试
#
# 覆盖对抗式审计第三轮找到的问题：
#   P3-21 `KEY = value`（等号带空格）被静默忽略
#         —— 而且键名左侧有空格时整行被当未知键跳过
#   P2-10 balance_on 忽略 conf_set_auto 返回值 → 假成功
#   P2-13 cmd_measure 静默跳过 → App 的"立即测速"看起来坏了
#   P3-19 doctor 建议写死安装路径
#   P3-20 输出名不剥 # 片段
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_cf.XXXXXX)"
trap 'rm -rf "$T"' EXIT INT TERM HUP
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin" LOCK_DIR="$T/lock"
. "$T/sr.sh"; trap - EXIT INT TERM HUP
export STATE_FILE="$T/st" PF_ANCHOR_FILE="$T/r.conf" PF_ANCHOR="smartroute"

echo "== 1. KEY = value 带空格必须能解析（P3-21）=="
# `KEY = value` 是很自然的写法。以前值不 trim：v 变成 " value"，
# 数字键撞 *[!0-9]* 被静默丢弃，计数器/超时类参数从不上报——
# 用户改了配置没任何效果，也看不到提示。
cat > "$T/c1.conf" <<'EOF'
OK_N = 3
FAIL_N=4
  SPEED_RECHECK  =  600
BALANCE_MODE = weighted
	PING_TIMEOUT	=	2
MODE=auto
EOF
( conf_parse_file "$T/c1.conf"
  for kv in "OK_N:3" "FAIL_N:4" "SPEED_RECHECK:600" "BALANCE_MODE:weighted" "PING_TIMEOUT:2" "MODE:auto"; do
    k="${kv%%:*}"; want="${kv##*:}"
    eval "got=\$$k"
    [ "$got" = "$want" ] && echo "OK $k=$got" || echo "BAD $k got=[$got] want=[$want]"
  done ) > "$T/o1.txt" 2>&1
nbad="$(grep -c '^BAD' "$T/o1.txt")"
[ "$nbad" = "0" ] && ok "六种写法全部解析正确（含 Tab 缩进、前后空格）" || bad "有 $nbad 个没解析: $(grep '^BAD' "$T/o1.txt" | tr '\n' ' ')"
# 键名左侧有空格时，以前 %%[[:space:]]* 会把键削成空串 → 整行静默跳过
grep -Fq 'k="${k#"${k%%[![:space:]]*}"}"' smartroute.sh \
    && ok "键名 trim 用的是去头/去尾成对写法" || bad "键名 trim 写法仍会削掉左侧空格的键"
grep -q "第一招在键名" smartroute.sh \
    && ok "注释写清了旧写法为什么错" || bad "没说清旧写法的问题"

echo "== 2. balance_on 必须检查 conf_set_auto 返回值（P2-10）=="
# 以前两个返回值都丢掉，配置没落盘也照样打印"✅ 双网并发已开启"。
# 后果：重启后并发安全阀、weighted/fastest 重测全部静默停摆。
B="$(grep -n '^balance_on()' smartroute.sh | cut -d: -f1)"
sed -n "${B},$((B+200))p" smartroute.sh | grep -q 'if ! conf_set_auto BALANCE 1; then' \
    && ok "检查 BALANCE 写入结果" || bad "BALANCE 写入结果被忽略"
sed -n "${B},$((B+200))p" smartroute.sh | grep -q 'if ! conf_set_auto BALANCE_MODE' \
    && ok "检查 BALANCE_MODE 写入结果" || bad "BALANCE_MODE 写入结果被忽略"
sed -n "${B},$((B+200))p" smartroute.sh | grep -q "守护进程不会维护它" \
    && ok "失败时说明后果（不只是报错）" || bad "没说后果"
sed -n "${B},$((B+200))p" smartroute.sh | grep -q "balance_off quiet" \
    && ok "写入失败时回滚规则，不留半开状态" || bad "没回滚，会留下规则但配置说 0"

echo "== 3. cmd_measure 静默跳过必须说原因（P2-13）=="
# 以前直接跳到 cmd_measurements，打四行"未测"就结束——App 的
# "立即测速"按钮看起来坏了，而实际只是接口状态未就绪。
M="$(grep -n '^cmd_measure()' smartroute.sh | cut -d: -f1)"
sed -n "${M},$((M+40))p" smartroute.sh | grep -q "跳过测速" \
    && ok "跳过时明确说明原因" || bad "跳过时无声"
sed -n "${M},$((M+40))p" smartroute.sh | grep -q "守护进程判定以太网当前不可用" \
    && ok "逐项说明是哪个接口没就绪" || bad "没说是哪个接口"
sed -n "${M},$((M+40))p" smartroute.sh | grep -q "等守护进程跑过一轮" \
    && ok "告诉用户下一步该等什么" || bad "没说下一步"

echo "== 4. doctor 不写死安装路径（P3-19）=="
grep -q 'dirname "$0"' smartroute.sh \
    && ok "用 \$0 推安装目录" || bad "仍写死路径"
grep -q 'cd ~/Pictures/smartroute' smartroute.sh \
    && bad "还有写死的 ~/Pictures/smartroute" || ok "没有写死路径"

echo "== 5. 输出名必须剥 # 片段（P3-20）=="
# 只剥 query 不剥 # 的后果：URL 带锚点（CDN 直链常见）会存成
# "f.iso#sha=1" —— 扩展名变了，双击打不开，且难联想到是锚点导致。
grep -Fq 'out="${url%%#*}"' smartroute.sh \
    && ok "先剥 # 片段" || bad "没剥 # 片段"
grep -Fq 'out="${out##*/}"' smartroute.sh \
    && ok "再取 basename" || bad "没取 basename"
# 顺序：# 必须在 basename 之前，否则 "#f?a=1" 这种形态会先被 ? 截断。
# 三个替换写在同一行，比行号没意义——用字符串内位置比。
ORDER="$(awk '/out="\$\{url%%#\*\}/ {print index($0, "url%%#*"), index($0, "out##*/")}' smartroute.sh | head -1)"
_h="$(echo "$ORDER" | cut -d' ' -f1)"; _b="$(echo "$ORDER" | cut -d' ' -f2)"
[ -n "$_h" ] && [ -n "$_b" ] && [ "$_h" -lt "$_b" ] \
    && ok "剥 # 在取 basename 之前（位置 $_h < ${_b}）" || bad "顺序不对（# at $_h, basename at ${_b}）"
grep -q '\[ -n "$out" \] || out="download"' smartroute.sh \
    && ok "空文件名有兜底" || bad "空文件名没兜底"
# 行为验证：四种 URL 形态
_n=0
for u in "http://x/f.iso#sha=1" "http://x/f.iso?a=1" "http://x/f.iso#f?a=1" "http://x/f.iso?a=1#f"; do
    o="${u%%#*}"; o="${o%%\?*}"; o="${o##*/}"
    [ "$o" = "f.iso" ] && _n=$((_n+1))
done
[ "$_n" = "4" ] && ok "四种带锚点/query 的 URL 都得到 f.iso" || bad "只有 $_n/4 正确"

echo ""
echo "结果: $PASS 通过, $FAIL 失败"

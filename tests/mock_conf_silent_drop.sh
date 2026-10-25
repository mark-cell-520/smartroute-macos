#!/bin/bash
# 复现脚本（审计用）：配置文件里的非法值被静默丢弃，没有任何提示
#
# 结论（待验证）：conf_parse_file 里有个计数器 n（smartroute.sh:213 声明、
# 277-279 自增），注释说"计数留给调用方决定要不要提示"，但函数最后
# `return 0`，n 是局部变量、外部拿不到，唯一调用点（299 行）也不看返回值。
# 于是配置里每一行过不了校验的键值对都被无声吃掉：
#   · 用户手改 /Users/Shared/smartroute.conf 打错一个字符 → 毫无反应
#   · App 导入时至少还会报"N 行不合法已丢弃"，手改路径连这个都没有
#
# 运行: bash tests/repro_conf_silent_drop.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d /tmp/sr_sd.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/etc" "$T/state"
sed -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log\"|" \
    -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/lock\"|" \
    -e "s|^USER_CONF=.*|USER_CONF=\"$T/etc/user.conf\"|" \
    -e "s|^CONF=.*|CONF=\"$T/etc/system.conf\"|" \
    -e "s|^RULES_FILE=.*|RULES_FILE=\"$T/etc/smartroute.rules\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" smartroute.sh \
    | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"
: > "$T/etc/system.conf"

printf '# 用户级配置\nMODE=wifi\nOK_N=abc\nNC_TIMEOUT=100000\nWIFI_FAILOVER=yes\nBALANCE_MODE=weighted\n' \
    > "$T/etc/user.conf"
chmod 644 "$T/etc/user.conf"

cat > "$T/drv.sh" <<'EOF'
#!/bin/bash
. "$MOCK_SR"
eval "$SR_CODE"
EOF
chmod +x "$T/drv.sh"
run() { MOCK_SR="$T/sr.sh" SR_CODE="$1" bash "$T/drv.sh" 2>"$T/err"; }

echo "=== 配置文件内容（5 个键，其中 2 个值不合法）==="
sed 's/^/    /' "$T/etc/user.conf"

echo
echo "=== 解析过程：stdout / stderr / 退出码 ==="
out="$(run 'true')"; rc=$?
errcat="$(cat "$T/err")"
printf '    stdout: [%s]\n' "$out"
printf '    stderr: [%s]\n' "$errcat"
printf '    退出码: %s\n' "$rc"
if [ -z "$out" ] && [ -z "$errcat" ] && [ "$rc" = "0" ]; then
    bad "非法值被无声吃掉：无提示、无 stderr、退出码 0"
else
    ok "有反馈"
fi

echo
echo "=== 生效值 vs 配置文件（用户只能自己看出矛盾）==="
run 'for kv in "MODE|MODE" "OK_N|OK_N" "NC_TIMEOUT|NC_TIMEOUT" "WIFI_FAILOVER|WIFI_FAILOVER"; do
       k="${kv%%|*}"
       eval "v=\$$k"
       f="$(grep -m1 "^$k=" "$USER_CONF" | cut -d= -f2)"
       printf "    %-14s 生效=%-10s 文件里=%s\n" "$k" "$v" "$f"
     done'

echo
echo "=== smartroute config 的完整输出里，有没有"已忽略"这类字样 ==="
n="$(run 'cmd_config' | grep -cE '已忽略|被丢弃|无效|非法')"
printf '    出现次数: %s\n' "$n"
[ "$n" = "0" ] && bad "config 把默认值和文件内容并排打出来，却不说哪几行被忽略了" || ok "有提示"

echo
echo "结果: $PASS 通过, $FAIL 失败"

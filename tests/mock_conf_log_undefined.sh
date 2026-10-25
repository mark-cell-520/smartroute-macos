#!/bin/bash
# 复现脚本（审计用）：用户级配置权限被拒时，log 还没定义 → 打到 /usr/bin/log 上
#
# 结论（待验证）：smartroute.sh:299 在**定义 log() 之前**（log 在 301 行）
# 就调用 conf_parse_file "$USER_CONF"，而 conf_parse_file 的权限拒绝分支
# （246 行）要调 log。于是这个分支一触发，bash 找不到 log 函数，
# 落到 PATH 里的 /usr/bin/log（macOS 统一日志 CLI），把一整页 usage
# 打到 stderr。注释里说过"加载挪到 conf_parse_file 定义之后"，
# 但漏了 conf_parse_file 内部依赖的 log。
#
# 触发条件正是这段防御代码要防的场景：/Users/Shared 是 1777，
# 任何本地用户都能先创建 /Users/Shared/smartroute.conf；
# 默认 umask 002 建出来就是 664（群可写）→ 命中拒绝分支。
#
# 运行: bash tests/repro_conf_log_undefined.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d /tmp/sr_lu.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/etc" "$T/state"

mksrc() {
    sed -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log\"|" \
        -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
        -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/lock\"|" \
        -e "s|^USER_CONF=.*|USER_CONF=\"$T/etc/user.conf\"|" \
        -e "s|^CONF=.*|CONF=\"$T/etc/system.conf\"|" \
        -e "s|^RULES_FILE=.*|RULES_FILE=\"$T/etc/smartroute.rules\"|" \
        -e "\|^PATH=/usr/local/sbin:|d" \
        smartroute.sh | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"
}
mksrc
: > "$T/etc/system.conf"
printf 'MODE=wifi\n' > "$T/etc/user.conf"

echo "=== 1. 权限正常（644）：干净，无输出 ==="
chmod 644 "$T/etc/user.conf"
err="$(bash -c ". '$T/sr.sh'" 2>&1 1>/dev/null)"
[ -z "$err" ] && ok "stderr 为空" || { bad "stderr 有输出: $err"; }

echo
echo "=== 2. 用户级配置 664（群可写，umask 002 的默认产物）==="
chmod 664 "$T/etc/user.conf"
err="$(bash -c ". '$T/sr.sh'" 2>&1 1>/dev/null)"
printf '%s\n' "$err" | head -8 | sed 's/^/    /'
n="$(printf '%s\n' "$err" | grep -c .)"
printf '    （共 %s 行 stderr）\n' "$n"
if printf '%s' "$err" | grep -q '^log: Unknown subcommand'; then
    bad "拒绝分支调到了不存在的 log，落到 /usr/bin/log，喷出一页 usage"
else
    ok "没有误调外部 log"
fi
printf '%s' "$err" | grep -q 'usage:' && bad "用户/守护进程日志里会出现 \`log\` 命令的用法页" || ok "干净"

echo
echo "=== 3. 顺带确认：配置确实被跳过（这是设计意图，没问题）==="
chmod 664 "$T/etc/user.conf"
out="$(bash -c ". '$T/sr.sh'; echo \"MODE=\$MODE\"" 2>/dev/null)"
printf '    %s（用户级写的是 MODE=wifi）\n' "$out"
[ "$out" = "MODE=auto" ] && ok "群可写配置被拒绝解析（符合设计）" || bad "群可写配置居然生效了"

echo
echo "=== 4. 真实入口也一样（任何 smartroute 子命令都会触发）==="
chmod 666 "$T/etc/user.conf"
err="$(bash smartroute.sh status 2>&1 1>/dev/null | head -3)"
# 注意：真实入口用的是 /Users/Shared/smartroute.conf，这里只证明
# "脚本每次启动都会走一遍 conf_parse_file"这件事
printf '    （真实入口读的是 /Users/Shared/smartroute.conf，见下方人工核对步骤）\n'

echo
echo "结果: $PASS 通过, $FAIL 失败"

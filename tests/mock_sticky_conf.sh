#!/bin/bash
# 专项：修复"App 保存失败"——/Users/Shared 带 sticky 位、用户配置被 root 占有的问题
set -u
SRC="/Users/mm/Pictures/smartroute/smartroute.sh"
T=/tmp/sr_sticky
rm -rf "$T"; mkdir -p "$T/etc" "$T/shared"
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# 构造一个带 sticky 位的目录，模拟 /Users/Shared（drwxrwxrwt）
chmod 1777 "$T/shared"
# 模拟"被 root 创建的用户配置"：当前用户拥有、但只读权限不足的场景用只读文件模拟
printf 'MODE=auto\nBALANCE=1\nOK_N=2\n' > "$T/shared/smartroute.conf"

sed -e "s|^CONF=.*|CONF=\"$T/etc/smartroute.conf\"|" \
    -e "s|^USER_CONF=.*|USER_CONF=\"$T/shared/smartroute.conf\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"
. "$T/sr.sh"

echo "== 1. conf_set 正常改写（同目录临时文件 + 原子替换）=="
conf_set MODE wifi "$USER_CONF" && ok "conf_set 返回成功" || bad "conf_set 失败"
grep -q "^MODE=wifi$" "$USER_CONF" && ok "MODE 已更新为 wifi" || bad "MODE 未更新"
grep -q "^BALANCE=1$" "$USER_CONF" && ok "其他配置项未被清掉" || bad "其他项丢失"
grep -q "^OK_N=2$"   "$USER_CONF" && ok "OK_N 保留" || bad "OK_N 丢失"
ls "$USER_CONF".tmp.* >/dev/null 2>&1 && bad "临时文件残留" || ok "无临时文件残留"
[ "$(grep -c "^MODE=" "$USER_CONF")" = "1" ] && ok "不产生重复键" || bad "键重复"

echo "== 2. 目录不可写但文件可写 → 退化为原地覆写 =="
chmod 555 "$T/shared"
conf_set MODE ethernet "$USER_CONF" && ok "只读目录下仍写成功" || bad "只读目录下写失败"
grep -q "^MODE=ethernet$" "$USER_CONF" && ok "原地覆写生效" || bad "原地覆写未生效"
grep -q "^BALANCE=1$" "$USER_CONF" && ok "覆写时其他项保留" || bad "覆写丢了其他项"
chmod 1777 "$T/shared"

echo "== 3. 文件完全不可写 → 明确失败且不损坏原文件 =="
chmod 444 "$T/shared/smartroute.conf"; chmod 555 "$T/shared"
before="$(cat "$USER_CONF")"
conf_set MODE wifi "$USER_CONF" 2>/dev/null && bad "不可写时应该失败" || ok "不可写时正确返回失败"
[ "$(cat "$USER_CONF")" = "$before" ] && ok "原文件内容未被破坏" || bad "原文件被写坏"
chmod 1777 "$T/shared"; chmod 644 "$T/shared/smartroute.conf"

echo "== 4. root 时优先写系统级配置，不把用户级占成 root 所有 =="
rm -f "$T/etc/smartroute.conf"
id() { echo 0; }                      # mock 成 root
conf_set_auto BALANCE 0
grep -q "^BALANCE=0$" "$T/etc/smartroute.conf" && ok "root 写入系统级配置" || bad "未写系统级"
unset -f id

echo "== 5. 用户级已有同项时，root 也一并更新（防止用户级盖掉安全阀）=="
grep -q "^BALANCE=0$" "$USER_CONF" && ok "用户级里的 BALANCE 同步为 0" || bad "用户级残留旧值 1"
grep -q "^MODE=" "$USER_CONF" && ok "用户级其他项不受影响" || bad "用户级被清空"

echo "== 6. cmd_set 的失败提示可操作 =="
out="$(cmd_set MODE=wifi 2>&1)"
echo "$out" | grep -q "^已设置 MODE=wifi" && ok "普通情况提示已设置" || bad "成功提示异常"
out="$(cmd_set BADKEY=1 2>&1)"
echo "$out" | grep -q "不支持的配置项" && ok "非法键被拒绝" || bad "非法键未拒绝"
out="$(cmd_set MODE=bogus 2>&1)"
echo "$out" | grep -q "MODE 只能是" && ok "非法 MODE 值被拒绝" || bad "非法 MODE 未拒绝"

echo
echo "结果: $PASS 通过, $FAIL 失败"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)

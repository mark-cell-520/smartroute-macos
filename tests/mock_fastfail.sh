#!/bin/bash
# 快速故障转移：一个接口没网络时，另一个要尽快接上
#
# 原来的时序：FAIL_N=3 个周期 × StartInterval 20 秒 = 最少 60 秒才切换。
# 用户体感是"网断了快一分钟才恢复"。
#
# 现在：本周期内连续确认 RECONFIRM_TIMES 次，每次都失败就记一笔，
# 持续断网的检测降到约 26 秒（第 2 轮 20s + 周期内 10s 确认）。
#
# 运行: bash tests/mock_fastfail.sh
SRC="$(cd "$(dirname "$0")/.." && pwd)/smartroute.sh"
checks=0; failures=0
ok()  { checks=$((checks+1)); printf '  OK %s\n' "$1"; }
bad() { failures=$((failures+1)); printf '  XX %s\n' "$1"; }

echo "== 1. 常量与上限 =="
grep -q '^RECONFIRM_DELAY=' smartroute.sh && ok "有 RECONFIRM_DELAY" || bad "缺 RECONFIRM_DELAY"
grep -q '^RECONFIRM_TIMES=' smartroute.sh && ok "有 RECONFIRM_TIMES" || bad "缺 RECONFIRM_TIMES"
# 上限的意义：本周期总耗时必须明显小于 StartInterval(20s)，否则下一个实例
# 会被锁挡在门外，等于白白少轮询一次——那会让"快速"变成"更慢"。
# 行尾有注释，awk -F= 会把 "# 最多当场确认几次..." 一起抓进来。
# 先去掉 # 及之后的内容，再取数字。
_num() { awk -F= -v k="$1" '$1==k{sub(/#.*/,"",$2); gsub(/[^0-9]/,"",$2); print $2}' smartroute.sh; }
_rct="$(_num RECONFIRM_TIMES)"
_rcd="$(_num RECONFIRM_DELAY)"
_rbg="$(_num RECONFIRM_BUDGET)"
[ "${_rct:-0}" -ge 1 ] && [ "${_rcd:-0}" -ge 1 ] \
    && [ $(( _rct * _rcd )) -lt 15 ] \
    && ok "确认总耗时 ${_rct}x${_rcd}=$(( _rct * _rcd ))s < 15s（不会侵占下一个周期）" \
    || bad "确认耗时可能超过 StartInterval，导致少轮询一次"

# 预算的意义：非 root 下一次完整探测约 7 秒（ping 0.8 + nc 2 + curl 4）。
# 没有预算上限时，两次确认就是 7+3+7+3=20 秒，正好顶到 StartInterval，
# 下一个守护实例被锁挡在门外、白白少轮询一次——"快速"变成"更慢"。
[ "${_rbg:-0}" -ge 1 ] && [ "${_rbg:-99}" -lt 15 ] \
    && ok "有 ${_rbg}s 预算硬上限（确认耗时不会侵占下一个 20s 周期）" \
    || bad "缺预算上限，确认可能侵占下一个周期导致少轮询一次"
awk '/^cmd_watch\(\)/,/^}/' smartroute.sh | grep -q '_rc_deadline' \
    && ok "循环里按 deadline 截断，不是死等满次数" || bad "没有按 deadline 截断"
awk '/^cmd_watch\(\)/,/^}/' smartroute.sh | grep -q '预算上限' \
    && ok "预算用尽会记日志（用户能追溯为什么这次只加速了一点）" || bad "预算用尽没有日志"

echo "== 2. 只有当前接口失败时才确认（不浪费）=="
awk '/^cmd_watch\(\)/,/^}/' smartroute.sh | grep -q '_rc_role' \
    && ok "用 _rc_role 锁定要确认的接口" || bad "没有角色锁定"
awk '/^cmd_watch\(\)/,/^}/' smartroute.sh | grep -q 'cur.*=.*ACTIVE_ETH_DEV.*eth_res.*=.*fail' \
    && ok "当前是以太网且失败才确认" || bad "确认条件不对"
awk '/^cmd_watch\(\)/,/^}/' smartroute.sh | grep -q 'cur.*=.*ACTIVE_WIFI_DEV.*wifi_res.*=.*fail' \
    && ok "当前是 Wi-Fi 且失败才确认" || bad "Wi-Fi 确认条件不对"

echo "== 3. 确认失败必须真的记上笔数（否则白等）=="
# 少了这一步，快速确认只是"多等几秒然后照样只记一笔"，检测时间一点没缩短
awk '/^cmd_watch\(\)/,/^}/' smartroute.sh | grep -q 'update_streak eth fail' \
    && ok "确认失败会追加记 eth 的笔数" || bad "确认失败没有记数，白等"
awk '/^cmd_watch\(\)/,/^}/' smartroute.sh | grep -q 'update_streak wifi fail' \
    && ok "确认失败会追加记 wifi 的笔数" || bad "确认失败没有记 wifi 笔数"
# 次数要能变（RECONFIRM_TIMES 可能大于 1），不能写死 = "1"
awk '/^cmd_watch\(\)/,/^}/' smartroute.sh | grep -q '_rc_eth" \]' \
    && ok "按实际确认次数循环记笔" || bad "记笔次数写死了"

echo "== 4. 确认时恢复了就不加速（防抖动误切）=="
awk '/^cmd_watch\(\)/,/^}/' smartroute.sh | grep -q '当场确认恢复' \
    && ok "恢复时会说明并停止加速" || bad "恢复时没有反馈"

echo ""
echo "结果: $((checks - failures)) 通过, $failures 失败"

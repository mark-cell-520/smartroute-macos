#!/bin/bash
# 测试 uninstall.sh 的覆盖完整性 —— 防止"卸载留残留"回归
#
# 思路：主脚本 smartroute.sh 会创建一堆文件/规则/路由，卸载脚本必须一个不漏地覆盖。
# 这里做两件事：
#   1. 静态检查：smartroute.sh 里出现的每个持久化路径，uninstall.sh 都必须提到
#   2. 行为检查：--dry-run 模式下不允许真的动任何东西（不能误删用户数据）
#
# 运行: bash tests/mock_uninstall.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

SRC=smartroute.sh
UNI=uninstall.sh

echo "=== 1. 卸载脚本覆盖所有持久化路径 ==="
# smartroute.sh 里会写入的持久化位置（排除纯读取的 /etc/pf.conf 和临时文件）
PATHS=(
    "/usr/local/bin/smartroute"
    "/etc/smartroute.conf"
    "/Users/Shared/smartroute.conf"
    "/Users/Shared/smartroute.rules"
    "/var/db/smartroute"
    "/var/db/smartroute/state"
    "/var/db/smartroute/pf.state"
    "/var/log/smartroute.log"
    "/var/log/smartroute.out"
    "/var/log/smartroute.err"
    "/etc/pf.anchors/com.user.smartroute"
    "/Library/LaunchDaemons/com.user.smartroute.plist"
    "/var/run/smartroute.lock"
)
# covered <路径>：要么卸载脚本直接提到它，要么它所在的目录被 rm -rf 干掉了
covered() {
    local p="$1" d
    grep -qF "$p" "$UNI" && return 0
    # 逐级往上找父目录，看有没有被 rm -rf
    d="$(dirname "$p")"
    while [ "$d" != "/" ] && [ "$d" != "." ]; do
        grep -qF "rm -rf $d" "$UNI" && return 0
        d="$(dirname "$d")"
    done
    return 1
}
for p in "${PATHS[@]}"; do
    if covered "$p"; then ok "覆盖 $p"; else bad "漏删 $p"; fi
done

echo "=== 2. pf 锚点规则与主机路由也要清 ==="
grep -q 'pfctl -a "\$ANCHOR" -F rules' "$UNI" && ok "会刷掉 pf 锚点规则" || bad "没有刷 pf 锚点规则"
grep -q 'route delete -host' "$UNI"             && ok "会删探测主机路由" || bad "没有删主机路由"
grep -q 'pf_enabled_by_us=1' "$UNI"             && ok "会判断并关掉我们自己开的 pf" || bad "不管 pf 是否我们开的"
grep -q 'bootout system/com.user.smartroute' "$UNI" && ok "会 bootout 守护进程" || bad "不停守护进程"

echo "=== 3. 临时文件残留清理 ==="
grep -q 'smartroute.conf.tmp' "$UNI"  && ok "清理 .conf.tmp 残留" || bad "不清理 .conf.tmp"
grep -q '.smartroute.probe.\*' "$UNI" && ok "清理 /tmp 探测残留" || bad "不清理 /tmp 探测残留"
# smartroute.sh 自己不该再产生 probe 临时文件（已改为 stdout 两行）
if grep -q 'PROBE_DETAIL_FILE' "$SRC"; then bad "smartroute.sh 仍在使用 PROBE_DETAIL_FILE 临时文件"; else ok "smartroute.sh 不再产生 /tmp 探测临时文件"; fi

echo "=== 4. dry-run 安全性：不允许真的改东西 ==="
# 用一个假 root 环境跑 dry-run（把 root 检查短路），断言输出里全是"将删除"
TMPU=$(mktemp /tmp/uninstall_dryrun.XXXX.sh)
sed 's/^if \[ "\$(id -u)" -ne 0 \]; then/if false; then/' "$UNI" > "$TMPU"
OUT=$(bash "$TMPU" --dry-run 2>&1)
rm -f "$TMPU"

if printf '%s' "$OUT" | grep -q "dry-run 结束"; then ok "dry-run 正常结束"; else bad "dry-run 未正常结束"; fi
if printf '%s' "$OUT" | grep -q "将删除"; then ok "dry-run 有预览输出"; else bad "dry-run 没有预览输出"; fi
# dry-run 里不允许出现"已删除/已刷掉/已 bootout"这类真动作的标志
if printf '%s' "$OUT" | grep -qE "已删除|已刷掉|已 bootout|已 unload"; then
    bad "dry-run 里出现了真实动作的标志（会误删！）"
else
    ok "dry-run 未执行任何真实动作"
fi

echo "=== 5. 参数解析 ==="
for a in --yes --dry-run --keep-logs --help; do
    if grep -q -- "$a" "$UNI"; then ok "支持参数 $a"; else bad "不支持参数 $a"; fi
done
# 未知参数必须报错退出，不能静默忽略
OUT=$(bash "$UNI" --bogus-arg 2>&1); RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "未知参数"; then
    ok "未知参数会报错退出"
else
    bad "未知参数没有报错（危险：可能静默执行）"
fi

echo "=== 6. 非 root 必须拒绝 ==="
# 当前沙箱不是 root，直接跑应该被拒
OUT=$(bash "$UNI" --yes 2>&1); RC=$?
if [ "$(id -u)" -ne 0 ]; then
    if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "sudo"; then
        ok "非 root 运行时拒绝执行并提示用 sudo"
    else
        bad "非 root 时没有拒绝（危险）"
    fi
else
    echo "  - 当前是 root，跳过该项"
fi

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

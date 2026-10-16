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
    # 曾经漏过这个：install.sh 会装免权限扫描 helper，卸载清单里没有，
    # 用户卸完软件还留一个 /usr/local/bin/smartroute-wifiscan 在系统里。
    "/usr/local/bin/smartroute-wifiscan"
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

echo "=== 4b. --keep-app：App 内调用时不删自己 ==="
# App 里的"彻底卸载"按钮会带 --keep-app，否则会把正在运行的 App 删掉
TMPK=$(mktemp /tmp/uninstall_keepapp.XXXX.sh)
sed 's/^if \[ "\$(id -u)" -ne 0 \]; then/if false; then/' "$UNI" > "$TMPK"
OUTK=$(bash "$TMPK" --dry-run --keep-app 2>&1)
rm -f "$TMPK"
if printf '%s' "$OUTK" | grep -q "保留App=1"; then ok "识别 --keep-app"; else bad "--keep-app 没被识别"; fi
if printf '%s' "$OUTK" | grep -q "将删除 /Applications/SmartRoute.app"; then
    bad "--keep-app 模式下仍要删 App（会自杀）"
else
    ok "--keep-app 模式下不删 App"
fi
# 同样要短路 root 检查，否则脚本在第一行就退出了
TMPN=$(mktemp /tmp/uninstall_noapp.XXXX.sh)
sed 's/^if \[ "\$(id -u)" -ne 0 \]; then/if false; then/' "$UNI" > "$TMPN"
OUTK2=$(bash "$TMPN" --dry-run 2>&1)
rm -f "$TMPN"
if printf '%s' "$OUTK2" | grep -q "保留App=0"; then ok "不带旗标时保留App=0"; else bad "保留App 标志异常"; fi
if printf '%s' "$OUTK2" | grep -q "将删除 /Applications/SmartRoute.app"; then
    ok "不带旗标时会删 App"
else
    bad "不带旗标时反而不删 App（用户会抱怨卸不干净）"
fi

echo "=== 4c. 新残留来源必须覆盖 ==="
for pat in 'smartroute.conf.bak' 'smartroute.conf.tmp' 'smartroute.rules' 'com.user.smartroute.app.plist'; do
    if grep -qF "$pat" "$UNI"; then ok "清理 $pat"; else bad "漏删 $pat"; fi
done

echo "=== 5. 参数解析 ==="
for a in --yes --dry-run --keep-logs --keep-app --help; do
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
echo "=== 9. install.sh 装的文件，uninstall.sh 必须都删（防再漏） ==="
# 上面那份 PATHS 是手写的，会漏。这里改成从 install.sh 里把实际安装的
# 文件路径抠出来，逐个要求卸载脚本覆盖——加新文件时忘了删就会红。
# 两种写法都要认：install -m 0755 src dst  和  cp src dst
inst_list="$(grep -oE '(install|cp)[[:space:]]+[^|]*[[:space:]]+/[A-Za-z0-9/._-]+$' install.sh \
            | grep -oE '/[A-Za-z0-9/._-]+$' | sort -u)"
# App  bundle 由用户自己拖废纸篓，不属于这里管
inst_list="$(printf '%s\n' "$inst_list" | grep -v 'SmartRoute.app')"
n_inst=0
for f in $inst_list; do
    n_inst=$((n_inst+1))
    covered "$f" && ok "install 的 $f 卸载时会清掉" || bad "install 装了 $f 但 uninstall 不清它"
done
[ "$n_inst" -ge 3 ] && ok "从 install.sh 识别出 $n_inst 个安装目标" || bad "只识别出 $n_inst 个，抠路径的正则可能失效了"

echo "== 9. UTF-8 locale 下脚本必须能跑（bash 3.2 的 $VAR+中文陷阱） =="
# 出过真 bug：bash 3.2 在 UTF-8 locale 下会把 $VAR 后面的多字节字符并进
# 变量名（isalnum 对 >=0x80 的字节返回真），而 uninstall.sh 有 set -u，
# 于是在删任何东西之前就 unbound variable 退出。
# 本测试专门在 UTF-8 locale 下跑——现有测试全在 C locale 下跑，永远抓不到。
for loc in en_US.UTF-8 zh_CN.UTF-8 C; do
    out="$(LC_ALL=$loc bash uninstall.sh --bogus 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && ok "locale=$loc 对非法参数返回非 0" || bad "locale=$loc 没报错"
    printf '%s' "$out" | grep -q "unbound variable" && bad "locale=$loc 触发 unbound variable" || ok "locale=$loc 没有 unbound variable"
    # 全角括号必须完整出现在输出里（被并进变量名时字符会消失）
    printf '%s' "$out" | grep -q "（用 --help 看用法）" && ok "locale=$loc 全角括号完整输出" || bad "locale=$loc 全角括号被吃掉: $out"
done
# 静态检查：源码里不能有 $VAR 后紧跟多字节字符的写法
n="$(python3 - <<'PYEOF2'
import re
bad = 0
for fn in ["uninstall.sh", "install.sh", "smartroute.sh",
           "build_release.sh", "build_app.sh", "build_dmg.sh", "sync-github.sh"]:
    for i, line in enumerate(open(fn, encoding="utf-8").read().split("\n"), 1):
        for m in re.finditer(r"\$[A-Za-z_][A-Za-z0-9_]*", line):
            e = m.end()
            if e < len(line) and ord(line[e]) > 0x2000 and line[e] not in " \t)}];,./=+*":
                print("  %s:%d: %s" % (fn, i, line.strip()[:60]))
                bad += 1
                break
print(bad)
PYEOF2
)"
[ "$n" = "0" ] && ok "源码无 $VAR+中文 陷阱" || bad "源码还有 $n 处 $VAR+中文 陷阱"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

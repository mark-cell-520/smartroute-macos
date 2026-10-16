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
# -F all 而不是 -F rules：和 balance_off 对齐。当前锚点里只有 pass 规则，
# 用 -F rules 侥幸干净，将来加了 nat/表就会漏。
grep -qE 'pfctl -a "\$ANCHOR" -F (rules|all)' "$UNI" && ok "会刷掉 pf 锚点规则" || bad "没有刷 pf 锚点规则"
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
# 但 install.sh 里守护进程 plist 写的是变量（DAEMON_PLIST="/Library/LaunchDaemons/$PLIST_LABEL.plist"），
# 直接抠路径抠不到——加新文件时忘了删，这条检查就瞎了。所以先把已知路径变量
# 还原成字面量再抠。只替换这几个明确的名字，不做通用 eval（不安全）。
inst_src="$(sed -e 's#\${PLIST_LABEL}#com.user.smartroute#g' \
                 -e 's#\$PLIST_LABEL#com.user.smartroute#g' \
                 -e 's#"\$DAEMON_PLIST"#/Library/LaunchDaemons/com.user.smartroute.plist#g' \
                 install.sh)"
inst_list="$(printf '%s\n' "$inst_src" \
            | grep -oE '(install|cp)[[:space:]]+[^|]*[[:space:]]+/[A-Za-z0-9/._-]+$' \
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

echo "=== 12. 服务顺序：备份要发生在改之前，卸载要还原 ==="
# reorder_first 用 networksetup -ordernetworkservices 把首选服务挪到第一位，
# 这是**持久化**修改：重启、重连都在，卸载软件本身不会还原。
# 以前全库没有备份，卸载也不还原不提，而脚本最后还印"网络设置未改动"——
# 用户在系统设置>网络里发现顺序被动过却不知道是谁干的，信任直接归零。
grep -q 'svc_order_backup_once' "$SRC" && ok "smartroute.sh 有服务顺序备份函数" || bad "没有服务顺序备份函数"
# 备份必须在 reorder_first 里被调用，且是在实际改顺序之前
_reorder_body="$(awk '/^reorder_first\(\)/,/^}/' "$SRC")"
printf '%s' "$_reorder_body" | grep -q 'svc_order_backup_once' \
    && ok "备份在 reorder_first 里被调用（改之前就存）" || bad "备份没接到 reorder_first 上，等于没备份"
# 备份要幂等：只存第一次。否则第二次切换会把"已改过的顺序"又存成原始顺序，
# 还原时就回到中间态，永远回不到真正的起点。
printf '%s' "$_reorder_body" | grep -q 'svc_order_backup_once' \
    && ok "reorder_first 调用了备份" || bad "reorder_first 没调用备份"
awk '/^svc_order_backup_once\(\)/,/^}/' "$SRC" | grep -q '\[ -s "\$SVC_ORDER_BAK" \] && return 0' \
    && ok "备份幂等：只存第一次（不会把改过的顺序存成原始顺序）" || bad "备份不幂等，会存错原始顺序"
# 备份用单独文件而不是 state：服务名可能含空格，拼进 key=value 会歧义
grep -q 'SVC_ORDER_BAK=' "$SRC" && ok "备份路径用变量（不是硬编码）" || bad "备份路径硬编码"
# 卸载必须还原，且必须在删 /var/db/smartroute 之前读
grep -q 'networksetup -ordernetworkservices "${_order\[@\]}"' "$UNI" \
    && ok "卸载会还原服务顺序" || bad "卸载不还原服务顺序"
_uni_body="$(cat "$UNI")"
# 还原的代码必须出现在 rm -rf /var/db/smartroute 之前
_restore_at="$(printf '%s\n' "$_uni_body" | grep -n 'ordernetworkservices' | head -1 | cut -d: -f1)"
_rmstate_at="$(printf '%s\n' "$_uni_body" | grep -n 'rm -rf /var/db/smartroute' | head -1 | cut -d: -f1)"
if [ -n "$_restore_at" ] && [ -n "$_rmstate_at" ] && [ "$_restore_at" -lt "$_rmstate_at" ]; then
    ok "还原发生在删状态目录之前（否则备份先没了）"
else
    bad "还原在删状态目录之后，备份已被删掉（还原:$_restore_at 删目录:$_rmstate_at）"
fi
# 服务名逐行读：服务名可能含空格（"Thunderbolt Bridge"），不能按空格拆
grep -q 'while IFS= read -r _s' "$UNI" && ok "逐行读服务名（容忍空格）" || bad "按空格拆服务名会拆错"
# 备份里的服务可能已不存在，networksetup 会整体失败——不能因此中断卸载
grep -q '还原服务顺序失败' "$UNI" && ok "还原失败有兜底提示（不让卸载中断）" || bad "还原失败会中断卸载"

echo "=== 13. 校验清单必须和删除清单一一对应 ==="
# 以前有四项"删了却不验"，结果 ✅ 零残留有时是假的。
# 用户唯一想从卸载得到的答案就是"真的干净了吗"，骗他一次之前所有
# 诚实的交代都作废。这里要求：每个 rm 目标都要出现在校验循环里。
_missing=0
for _f in /Users/Shared/smartroute.conf.tmp /var/log/smartroute.out.1 \
           /var/log/smartroute.err.1 /var/db/smartroute/svc_order_orig; do
    # 校验清单用 glob（如 smartroute.out.*），所以按前缀匹配
    _pre="${_f%.1}"
    if printf '%s\n' "$_uni_body" | grep -qF "$_pre"; then :; else
        bad "删了 $_f 但校验清单没有它（会假报 ✅）"; _missing=$((_missing+1))
    fi
done
[ "$_missing" -eq 0 ] && ok "删掉的轮转/临时文件都在校验清单里" || bad "$_missing 项删而不验"
# App 路径：用户可能放在 ~/Applications，硬编码 /Applications 会漏
printf '%s\n' "$_uni_body" | grep -qF 'HOME/Applications/SmartRoute.app' \
    && ok "App 路径同时查 ~/Applications（不只 /Applications）" || bad "App 路径只查 /Applications"
# 探测目标从配置读，不用硬编码 IP 列表
printf '%s\n' "$_uni_body" | grep -q 'PROBE_TARGETS' \
    && ok "探测目标从配置读（追得上用户自定义）" || bad "探测目标还是硬编码列表，会漏"
# .conf.bak 是 App 承诺的"后悔药"，不能静默删
if printf '%s\n' "$_uni_body" | grep -q 'rm -f /Users/Shared/smartroute.conf.bak'; then
    bad "还在静默删 .conf.bak（App 承诺过的后悔药）"
else
    ok "不再删 .conf.bak，改为保留并告知路径"
fi
# 默认路由和 pf 要如实报告，不能拍脑袋说"网络设置未改动"
printf '%s\n' "$_uni_body" | grep -q 'route -n get default' \
    && ok "卸载后报告默认路由真实状态" || bad "不报告默认路由"
printf '%s\n' "$_uni_body" | grep -q 'pfctl -s info' \
    && ok "卸载后报告 pf 真实状态" || bad "不报告 pf 状态"
# 只查可执行代码：注释里解释了"为什么不那么做"，直接 grep 会误判
_uni_code="$(printf '%s\n' "$_uni_body" | grep -v '^[[:space:]]*#')"
if printf '%s\n' "$_uni_code" | grep -q '网络设置未改动'; then
    bad "还印着「网络设置未改动」——服务顺序明明会改，这话不实"
else
    ok "删掉了「网络设置未改动」这句不实的话"
fi
# 失败不再说"可忽略"
if printf '%s\n' "$_uni_code" | grep -q '失败，可忽略'; then
    bad "还在说「失败，可忽略」——会把用户训练成忽视失败"
else
    ok "失败时给可照抄的手动命令，不说「可忽略」"
fi

echo "== 14. 默认路由：兜底钉上去的必须还原，且绝不能让用户断网 =="
# do_switch 的兜底会 route delete default + route add default -interface，
# 这样加出来的默认路由没有任何清理机制（EXIT trap 只清探测路由）。
# 卸完它还留着，默认路由就停在 smartroute 最后切的接口上——
# 用户只会觉得"卸载把网络搞坏了"。
_uni_body="$(cat "$UNI")"
printf '%s\n' "$_uni_body" | grep -q 'route delete default' \
    && ok "卸载会删掉默认路由让系统重新裁决" || bad "不还原被钉住的默认路由"
# 删之前必须先记下参数，否则加不回来
printf '%s\n' "$_uni_body" | grep -q '_d_gw=' \
    && ok "删之前记下网关参数（为了能加回来）" || bad "没记参数就删，加不回来"
# configd 没动静时必须原样加回——这是安全底线
printf '%s\n' "$_uni_body" | grep -q 'route_add_default "$_d_if" "$_d_gw"' \
    && ok "系统没重建就原样加回（绝不让用户断网）" || bad "删了不加回，用户会断网"
# 加不回来时要告诉用户怎么办，不能静默
printf '%s\n' "$_uni_body" | grep -q '请手动开关一次 Wi-Fi 或重启 Mac' \
    && ok "加不回来时给出恢复指引" || bad "加不回来时无声提示"

echo "== 15. 通知必须说人话 =="
# 开了通知的人收到"默认路由: en1 → en0"只会更困惑：en1 是什么？
# 我被切去了哪里？所以所有通知都要过 dev_cn 映射。
grep -q 'dev_cn()' "$SRC" && ok "smartroute.sh 有设备名人话映射" || bad "没有设备名映射"
# 每条通知都不能把设备名原样漏出去
_n=0
while IFS= read -r _line; do
    case "$_line" in
        *notify*)
            # 先把 $(dev_cn ...) 整段剥掉，剩下的若还有 $want/$cur 就是漏了映射。
            # 直接 grep '$want' 会把 $(dev_cn "$want") 里的也算上——最早就是这么
            # 写的，结果两条正确的通知被误判，白查一轮。
            _stripped="$(printf '%s' "$_line" | sed 's#\$(dev_cn [^)]*)#<已映射>#g')"
            if printf '%s' "$_stripped" | grep -q '\$want\|\$cur\|${cur'; then
                bad "通知里出现裸设备名: $_line"; _n=$((_n+1))
            fi
            ;;
    esac
done < <(grep 'notify "' "$SRC")
[ "$_n" -eq 0 ] && ok "所有通知都不漏裸设备名" || bad "$_n 条通知漏裸设备名"
# dev_cn 要覆盖 en0/en1 和空值（首次切换时 cur 是空的）
awk '/^dev_cn\(\)/,/^}/' "$SRC" | grep -q 'en0' && ok "映射覆盖 en0（以太网）" || bad "没映射 en0"
awk '/^dev_cn\(\)/,/^}/' "$SRC" | grep -q 'en1' && ok "映射覆盖 en1（Wi-Fi）" || bad "没映射 en1"
awk '/^dev_cn\(\)/,/^}/' "$SRC" | grep -q '""' && ok "映射覆盖空值（首次切换）" || bad "没映射空值，首次切换会显示空"
# 自动打开 Wi-Fi 的通知必须说原因——用户在手动关掉 Wi-Fi 的场景下
# 收到"已自动打开 Wi-Fi"格外不安，像软件在偷偷改他的设置
grep -q '网线上不了网，已自动打开 Wi-Fi 保持联网' "$SRC" \
    && ok "自动开 Wi-Fi 的通知说明了原因" || bad "自动开 Wi-Fi 没说原因"
# 自动关双网并发也要说原因
grep -q '有个接口上不了网，已自动关闭双网并发' "$SRC" \
    && ok "自动关并发的通知说明了原因" || bad "自动关并发没说原因"

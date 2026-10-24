#!/bin/bash
# 测试 install.sh
#
# 为什么必须测：install.sh 是用户接触产品的**第一步**，它挂了整个产品就对
# 这个用户不存在。而它此前一个测试都没有。
#
# 这一轮修的最严重问题：launchctl bootstrap 失败后被 `|| true` 静默吞掉，
# 用户以为装好了，实际守护进程从没跑过——几周后才发现"这东西没动"，
# 那时他已记不得安装过程，无从排查。
#
# 方法：install.sh 写的是 /usr/local/bin、/Library/LaunchDaemons、/etc 这些
# 绝对路径，测试里不能真写。所以复制一份并把路径重定向到临时目录，
# 验的是**分支逻辑和提示文案**。同时在最后静态断言原文件的路径没被改错，
# 避免"测了一份改写版，真版路径错了没人知道"。
#
# 运行: bash tests/mock_install.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_install.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root/usr/local/bin" "$T/root/Library/LaunchDaemons" "$T/root/etc" "$T/bin"
: > "$T/launchctl.log"; : > "$T/sudo.log"

# ---------- mock ----------
cat > "$T/bin/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_SUDO_LOG"
exec "$@"
EOF
chmod +x "$T/bin/sudo"
cat > "$T/bin/launchctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_LAUNCHCTL_LOG"
case "${1:-}" in
    bootstrap) exit "${MOCK_BOOTSTRAP_RC:-0}" ;;
    kickstart) exit "${MOCK_KICKSTART_RC:-1}" ;;
    load)      exit "${MOCK_LOAD_RC:-1}" ;;
    print)     exit "${MOCK_PRINT_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$T/bin/launchctl"
cat > "$T/bin/install" <<'EOF'
#!/bin/bash
# 真正干活的 install：把最后一个参数（目标）建出来
while [ $# -gt 2 ]; do shift; done
[ $# -eq 2 ] || exit 0
cp "$1" "$2" 2>/dev/null && chmod 0755 "$2"
EOF
chmod +x "$T/bin/install"
cat > "$T/bin/tee" <<'EOF'
#!/bin/bash
exec /usr/bin/tee "$@"
EOF
chmod +x "$T/bin/tee"
# chown/chmod 必须 mock：测试不是 root，chown root:wheel 必然失败，
# 而 install.sh 有 set -e，一失败整装中断——测出来全是假失败。
cat > "$T/bin/chown" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/chown"
cat > "$T/bin/chmod" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/chmod"

# 脚本固定放 $T/src/。install.sh 第一件事是 cd "$(dirname "$0")"，
# 之后 smartroute.sh、com.user.smartroute.plist、wifiscan 全都相对于它。
# 放这里的好处：四个候选位置（.、../MacOS、tools、../tools）全部落在 $T 内，
# 不会写到 /tmp 外面去。
mkdir -p "$T/src"
cp smartroute.sh com.user.smartroute.plist "$T/src/"

mk_script() {
    sed -e "s#/usr/local/bin#$T/root/usr/local/bin#g" \
        -e "s#/Library/LaunchDaemons#$T/root/Library/LaunchDaemons#g" \
        -e "s#/etc/smartroute.conf#$T/root/etc/smartroute.conf#g" \
        install.sh > "$T/src/install_test.sh"
}

run_install() {
    : > "$T/launchctl.log"; : > "$T/sudo.log"
    MOCK_LAUNCHCTL_LOG="$T/launchctl.log" MOCK_SUDO_LOG="$T/sudo.log" \
    PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$T/src/install_test.sh" 2>&1
}

echo "== 1. 正常安装：三步都做，且验证守护进程真的起来了 =="
mk_script
out="$(run_install)"; rc=$?
[ "$rc" -eq 0 ] && ok "退出码 0" || bad "退出码 $rc: $out"
[ -x "$T/root/usr/local/bin/smartroute" ] && ok "主程序装上了" || bad "主程序没装上"
grep -q "^bootstrap " "$T/launchctl.log" && ok "注册了守护进程" || bad "没注册守护进程"
# 关键：装完必须验证，不能注册完就完事
grep -q "^print " "$T/launchctl.log" \
    && ok "装完验证守护进程真的在跑（不靠猜）" || bad "注册后没验证，静默失败就是这么来的"

echo "== 2. 守护进程起不来 → 必须报错退出，并告诉用户卡在哪 =="
mk_script
out="$(MOCK_PRINT_RC=1 run_install)"; rc=$?
[ "$rc" -ne 0 ] && ok "起不来时退出码非 0（不再静默）" || bad "起不来却返回 0，用户会以为装好了"
printf '%s' "$out" | grep -q "守护进程没起来" \
    && ok "明确说守护进程没起来" || bad "没说清失败原因"
printf '%s' "$out" | grep -q "bootstrap" \
    && ok "给了手动排查命令（可操作）" || bad "没给排查命令，用户只能干瞪眼"
# 主程序此时已经装好了，要说清楚，别让用户以为全盘失败
printf '%s' "$out" | grep -q "程序文件、配置文件都已装好" \
    && ok "说清哪些成了哪些没成（不夸大失败）" || bad "没说清已完成的部分"

echo "== 3. bootstrap 失败但 kickstart 成功（重复安装的正常路径）=="
mk_script
out="$(MOCK_BOOTSTRAP_RC=1 MOCK_KICKSTART_RC=0 run_install)"; rc=$?
[ "$rc" -eq 0 ] && ok "重复安装不报错" || bad "重复安装失败: $out"
printf '%s' "$out" | grep -q "已加载过" \
    && ok "说明是重复安装并用新代码重启了" || bad "没说清重复安装的处理"

echo "== 4. 旧版 macOS：bootstrap/kickstart 都不行，走 load =="
mk_script
out="$(MOCK_BOOTSTRAP_RC=1 MOCK_KICKSTART_RC=1 MOCK_LOAD_RC=0 run_install)"; rc=$?
[ "$rc" -eq 0 ] && ok "load 路径也能装上" || bad "load 路径失败: $out"
printf '%s' "$out" | grep -q "旧版 macOS" && ok "说明了走的哪条路" || bad "没说走哪条路"

echo "== 5. 全都失败 → 报错 =="
mk_script
out="$(MOCK_BOOTSTRAP_RC=1 MOCK_KICKSTART_RC=1 MOCK_LOAD_RC=1 MOCK_PRINT_RC=1 run_install)"; rc=$?
[ "$rc" -ne 0 ] && ok "三条路都失败时报错退出" || bad "三条路都失败却返回 0"

echo "== 6. 配置已存在 → 一个字都不改 =="
mk_script
printf 'MODE=speed\nBALANCE=1\n' > "$T/root/etc/smartroute.conf"
out="$(run_install)" >/dev/null
grep -q "^MODE=speed$" "$T/root/etc/smartroute.conf" \
    && ok "用户的 MODE=speed 保住了（没被重置成 auto）" || bad "配置被覆盖了，等于偷偷改用户设置"
grep -q "^BALANCE=1$" "$T/root/etc/smartroute.conf" && ok "BALANCE 也保住了" || bad "BALANCE 被覆盖"

echo "== 7. 配置不存在 → 创建默认值 =="
mk_script
rm -f "$T/root/etc/smartroute.conf"
run_install >/dev/null
grep -q "^MODE=auto$" "$T/root/etc/smartroute.conf" && ok "默认 MODE=auto" || bad "没创建默认配置"

echo "== 8. wifiscan：四个位置都能找到 =="
# 候选位置（相对 $T/src/）：.、../MacOS、tools、../tools
# 每个位置试一次，试完就删，避免上一个位置的残留让下一个误判为找到。
for _rel in "" "tools"; do
    mk_script
    case "$_rel" in
        "")     _d="$T/src" ;;
        MacOS|tools) _d="$T/src/$_rel" ;;
    esac
    mkdir -p "$_d"
    printf '#!/bin/bash\necho wifiscan\n' > "$_d/wifiscan"; chmod +x "$_d/wifiscan"
    out="$(run_install 2>&1)"
    if [ -x "$T/root/usr/local/bin/smartroute-wifiscan" ]; then
        ok "位置 [$_rel] 找到了 helper"
    else
        bad "位置 [$_rel] 没找到: $(printf '%s' "$out" | grep -i wifiscan | head -2)"
    fi
    rm -rf "$T/root/usr/local/bin/smartroute-wifiscan" "$_d/wifiscan"
done
# ../MacOS 和 ../tools 是 $T/src 的上一级
for _rel in "MacOS" "tools"; do
    mk_script
    mkdir -p "$T/$_rel"
    printf '#!/bin/bash\necho wifiscan\n' > "$T/$_rel/wifiscan"; chmod +x "$T/$_rel/wifiscan"
    out="$(run_install 2>&1)"
    if [ -x "$T/root/usr/local/bin/smartroute-wifiscan" ]; then
        ok "位置 [../$_rel] 找到了 helper"
    else
        bad "位置 [../$_rel] 没找到: $(printf '%s' "$out" | grep -i wifiscan | head -2)"
    fi
    rm -rf "$T/root/usr/local/bin/smartroute-wifiscan" "$T/$_rel/wifiscan"
done

echo "== 9. wifiscan 缺失 → 警告但不中断，并说清退化到什么程度 =="
mk_script
out="$(run_install)"; rc=$?
[ "$rc" -eq 0 ] && ok "缺 helper 不影响主安装" || bad "缺 helper 导致安装失败: $out"
printf '%s' "$out" | grep -q "没找到 wifiscan" && ok "明确警告" || bad "没警告"
printf '%s' "$out" | grep -q "不影响自动选路主功能" \
    && ok "说清"缺了也能用"（不吓用户）" || bad "没说清影响范围"
printf '%s' "$out" | grep -q "已找过" \
    && ok "列出已找过的路径（可操作）" || bad "没说找过哪"

echo "== 10. 提示里不能有不存在的命令（回归防护）=="
# 历史上这里写过 "smartroute watch stop/start"，而入口只有 watch|once|run，
# 用户照敲只会得到一段 usage，反而更困惑。
mk_script
out="$(run_install)"
printf '%s' "$out" | grep -q "smartroute watch stop\|smartroute watch start" \
    && bad "提示里有不存在的子命令" || ok "没有不存在的子命令"
printf '%s' "$out" | grep -q "launchctl bootout" \
    && ok "暂停用的是真实的 launchctl 命令" || bad "没给暂停方法"

echo "== 11. 装完要说清"会发生什么"和"怎么撤销"（心理安抚）=="
mk_script
out="$(run_install)"
printf '%s' "$out" | grep -q "接下来会发生什么" && ok "说了会发生什么" || bad "没说会发生什么"
printf '%s' "$out" | grep -q "不动你的 VPN" \
    && ok "明确说不碰 VPN/DNS/驱动（消顾虑）" || bad "没打消顾虑"
printf '%s' "$out" | grep -q "想暂停或撤销" && ok "给了暂停/撤销入口" || bad "没给撤销入口"
# 卸载安全性的说法必须和 uninstall.sh 的实际行为一致。
# 以前写"卸载不动你的网络设置"，而服务顺序明明会被改——说了一句假话，
# 用户发现对不上时，之前所有诚实的交代都作废。现在按实际行为说。
printf '%s' "$out" | grep -q "卸载会还原网络服务顺序" \
    && ok "如实说卸载会还原服务顺序" || bad "没说卸载会还原什么"
printf '%s' "$out" | grep -q "DNS/VPN/代理都没动过" \
    && ok "说清没动过什么" || bad "没说没动过什么"

echo "== 12. 静态断言：原文件的路径没被测试改写 mask 掉 =="
# 测试跑的是改写路径后的副本。若原文件路径写错，测试照样过——
# 所以这里直接查原文件。
grep -q "^sudo install -m 0755 smartroute.sh /usr/local/bin/smartroute$" install.sh \
    && ok "主程序装到 /usr/local/bin/smartroute" || bad "主程序路径不对"
grep -q "^DAEMON_PLIST=\"/Library/LaunchDaemons/\$PLIST_LABEL.plist\"$" install.sh \
    && ok "守护进程 plist 在 /Library/LaunchDaemons" || bad "plist 路径不对"
grep -q 'sudo launchctl print "system/\$PLIST_LABEL"' install.sh \
    && ok "装完真的去验证守护进程" || bad "原文件缺少守护进程验证"
# 只查可执行代码，跳过注释——原文件注释里解释了旧 bug 是什么，
# 直接 grep 会把那句说明也判成问题。
_code_or="$(grep -v '^[[:space:]]*#' install.sh | grep -c '|| true')"
[ "$_code_or" -eq 0 ] && ok "没有 '|| true' 静默吞失败" || bad "原文件里还有 $_code_or 处 '|| true' 吞失败"

echo "== 13. App 候选按版本号选最新，且不提供降级命令 =="
# 出过真事：候选列表写死顺序，永远取 dist/SmartRoute-2.2（10 月 19 日的 2.2
# 构建），install.sh 于是每次重装都提示"App 是旧版"并给出把用户降级回 2.2 的
# 复制命令——而仓库根的 SmartRoute.app 才是当前源码构建的 2.5。用户照抄提示
# 就把 v2.3-v2.5 的改进全丢了。现在按 CFBundleShortVersionString 选最大。

# 13a) 抽真的选择逻辑来跑（不重写一遍，重写就会和源漂移）
_sel_block="$(awk '/^NEWAPP=""; NEWVER=""$/,/^fi$/' install.sh)"
[ -n "$_sel_block" ] && ok "能从 install.sh 抽出候选选择块" || bad "选择块没了（被改名或删了？）"
NEWAPP=""; NEWVER=""; _cands=""
eval "$_sel_block"
if [ "$NEWVER" = "2.5" ] && [ "$NEWAPP" = "$(pwd)/SmartRoute.app" ]; then
    ok "三个候选里选中版本最高的（$NEWVER → 仓库根 SmartRoute.app）"
else
    bad "选错了：版本 $NEWVER 路径 $NEWAPP（dist 里两个 2.2 不应赢）"
fi

# 13b) 版本比较的语义：sort -V 必须是版本序不是字典序
#     （2.10 > 2.9；字符串比较会判反，于是"不降级"闸门形同虚设）
_max="$(printf '%s\n%s\n' 2.9 2.10 | sort -V | tail -1)"
[ "$_max" = "2.10" ] && ok "sort -V 版本序正确（2.10 > 2.9）" || bad "版本序错成字典序：max=$_max"
# 闸门表达式本身（和 install.sh 的 elif 条件同构）
_g2() { [ -n "$2" ] && [ "$(printf '%s
%s
' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }
_g2 2.2 2.5 && ok "候选 2.2 vs 已装 2.5 → 判为不更新（拒降级）" || bad "2.2 竟算比 2.5 新"
_g2 2.5 2.5 && ok "同版本 → 判为不更新（不给无意义重装命令）" || bad "同版本判定反了"
_g2 2.5 2.2 && bad "2.5 vs 2.2 竟判成不更新" || ok "候选 2.5 vs 已装 2.2 → 判为可更新"

# 13c) 静态：降级拒绝分支和版本选择必须在原文件里
grep -q 'sort -V' install.sh && ok "候选排序用 sort -V（版本序）" || bad "没有 sort -V，选择逻辑被改了"
grep -q '不提供降级命令' install.sh && ok "拒绝降级的提示在位" || bad "拒绝降级分支被删了"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# 行为测试：smartroute boost 一键配置四项能力
#
# 背景：用户提的四项需求（无网络自动切换、网速增加、双网并发、Wi-Fi 自动寻找）
# 散在四个配置键里，其中两项默认关闭、一项还要额外 sudo 加载 pf 规则。
# 用户得知道该调哪几个旋钮、按什么顺序，本身就是负担；而且 MODE 选 auto
# 还是 speed 取决于"要不要顺便提速"，选错了需求 2 就静默不生效。
#
# cmd_boost 把这些一次配好。这个测试要验证：
#   1. 四个键真的写进了配置文件（不是只改内存变量）
#   2. 非 root 时必须明确提示还要 sudo（不能假装已经配好了）
#   3. 某一个键写失败时，后面的键照样要写（不能一失败就整体放弃）
#   4. MODE 选的是 speed 而不是 auto——speed 自带可用性兜底，
#      同时覆盖"无网络自动切换"和"网速增加"两项
#
# 运行: bash tests/mock_boost.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

SRC="$(pwd)/smartroute.sh"
T="$(mktemp -d /tmp/sr_boost.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/etc" "$T/state" "$T/log" "$T/run"

# id 替身：默认报非 root（1000），可用 MOCK_UID 覆盖
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo "${MOCK_UID:-1000}"
exit 0
EOF
chmod +x "$T/bin/"*

# 剥掉入口，只保留到 cmd_boost 之后，然后显式调用它。
# 不能像别的测试那样 source 完整脚本再调函数——脚本末尾有 main "$@"，
# source 会直接跑入口。用 awk 截到入口前，再手工追加调用。
mksr() {   # $1=USER_CONF 路径
    sed -e "s|^CONF=.*|CONF=\"$T/etc/smartroute.conf\"|" \
        -e "s|^USER_CONF=.*|USER_CONF=\"$1\"|" \
        -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
        -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log/l\"|" \
        -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/l\"|" \
        -e "s|^SVC_ORDER_BAK=.*|SVC_ORDER_BAK=\"$T/state/svc\"|" \
        -e "s|^PF_ANCHOR_FILE=.*|PF_ANCHOR_FILE=\"$T/etc/pf.anchor\"|" \
        -e "\|^PATH=/usr/local/sbin:|d" \
        "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}'
}

runboost() {   # $1=USER_CONF 路径
    { mksr "$1"; echo 'cmd_boost'; } > "$T/run.sh"
    bash "$T/run.sh" 2>&1
}

echo "== 1. 四个键真的写进配置文件 =="
U="$T/etc/user.conf"
: > "$U"
o="$(runboost "$U")"
grep -q "^MODE=speed$" "$U"            && ok "MODE=speed 已写入" || bad "MODE 没写入: $(cat "$U")"
grep -q "^WIFI_FAILOVER=1$" "$U"       && ok "WIFI_FAILOVER=1 已写入" || bad "WIFI_FAILOVER 没写入"
grep -q "^BALANCE=1$" "$U"             && ok "BALANCE=1 已写入" || bad "BALANCE 没写入"
grep -q "^BALANCE_MODE=weighted$" "$U" && ok "BALANCE_MODE=weighted 已写入" || bad "BALANCE_MODE 没写入"

echo "== 2. MODE 必须是 speed 而不是 auto =="
# speed 分支末尾有 elif 兜底：只有一条线可用时也会切过去，
# 所以它同时覆盖"无网络自动切换"和"网速增加"。选 auto 会让需求 2 静默失效。
if grep -q "^MODE=auto$" "$U"; then bad "写成了 auto（网速优先会静默失效）"; else ok "不是 auto"; fi
# 并且源码里 speed 分支真的带可用性兜底
awk '/^        speed\)/,/^            ;;/' "$SRC" | grep -q 'elif \[ "\$eth_ok" -eq 1 \]' \
    && ok "speed 分支带可用性兜底（同时覆盖无网络切换）" || bad "speed 分支没有兜底，选 speed 会丢掉 failover"

echo "== 3. 非 root 必须提示还要 sudo =="
# 不提示的话，用户会以为 pf 规则已经加载、并发已经生效，然后发现下载
# 没有任何叠加效果——这是"软件撒谎"，比报错更糟。
echo "$o" | grep -q "sudo smartroute balance on weighted" \
    && ok "明确提示需要 sudo 加载 pf 规则" || bad "没提示还要 sudo"
# 而且不能声称 pf 规则已加载
echo "$o" | grep -q "pf 分流规则已加载" \
    && bad "非 root 却声称 pf 规则已加载（撒谎）" || ok "没有谎称 pf 已加载"

echo "== 4. 后续步骤要可操作 =="
echo "$o" | grep -q "smartroute status" && ok "提示了查看状态" || bad "没提示查看状态"
echo "$o" | grep -q "smartroute fetch" && ok "提示了下载命令" || bad "没提示下载命令"

echo "== 5. 某个键写失败不能中断后面的键 =="
# 把 WIFI_FAILOVER 从 VALID_KEYS 里挖掉，模拟"这个键不被支持"，
# 看 BALANCE / BALANCE_MODE 是否仍然写进去了。
U2="$T/etc/user2.conf"; : > "$U2"
# 只从 VALID_KEYS 里挖掉 WIFI_FAILOVER。
# 注意不能全局 sed 's/WIFI_FAILOVER //'——那会把 cmd_boost 里的
# "conf_set_kv WIFI_FAILOVER 1" 也改成 "conf_set_kv 1"，
# 于是报错信息变成"不支持的配置项: 1"，断言就永远对不上。
sed '/^VALID_KEYS=/s/ WIFI_FAILOVER / /' "$SRC" > "$T/sr_nokey.sh"
sed -i '' -e "s|^CONF=.*|CONF=\"$T/etc/smartroute.conf\"|" \
    -e "s|^USER_CONF=.*|USER_CONF=\"$U2\"|" \
    -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log/l\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/l\"|" \
    -e "s|^SVC_ORDER_BAK=.*|SVC_ORDER_BAK=\"$T/state/svc\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" "$T/sr_nokey.sh"
awk '/^# ---------------- 入口 ----------------/{exit} {print}' "$T/sr_nokey.sh" > "$T/sr_nokey2.sh"
{ cat "$T/sr_nokey2.sh"; echo 'cmd_boost'; } > "$T/run2.sh"
o2="$(bash "$T/run2.sh" 2>&1)"
grep -q "^BALANCE=1$" "$U2"             && ok "WIFI_FAILOVER 失败后 BALANCE 仍写入" || bad "一失败就整体放弃了"
grep -q "^BALANCE_MODE=weighted$" "$U2" && ok "BALANCE_MODE 仍写入" || bad "BALANCE_MODE 被跳过"
echo "$o2" | grep -q "WIFI_FAILOVER"     && ok "失败的那项有明确报错" || bad "失败项没报错"

echo "== 6. 幂等：重复跑不该报错或写坏 =="
U3="$T/etc/user3.conf"; : > "$U3"
runboost "$U3" >/dev/null 2>&1
runboost "$U3" >/dev/null 2>&1
_n="$(grep -c "^MODE=speed$" "$U3")"
[ "$_n" = "1" ] && ok "重复跑不产生重复键（$_n 处）" || bad "重复跑产生了 $_n 处 MODE=speed"

echo "== 7. 空配置文件也能写入（grep -v 退出码 bug 的回归）=="
# 这个 bug 是真事：grep -v 在文件为空时返回 1（"没有行被选中"），
# conf_set 用 && 串起来导致整链短路，写入被静默判成失败。用户看到
# "写入 xxx 失败"而文件完好、权限没问题，完全无法排查。
# 表现：smartroute set / boost 在 0 字节的用户配置上一律失败。
U4="$T/etc/user4.conf"
: > "$U4"                      # 0 字节，精确复现触发条件
{ mksr "$U4"; echo 'conf_set_kv MODE speed; echo "RC=$?"'; } > "$T/run4.sh"
o4="$(bash "$T/run4.sh" 2>&1)"
echo "$o4" | grep -q "RC=0" && ok "空配置文件上 conf_set_kv 返回 0" || bad "空配置文件上失败: $o4"
grep -q "^MODE=speed$" "$U4" && ok "空配置文件被正确写入" || bad "空配置文件没写进去"

# 只有注释行的文件（install.sh 创建的就是这种）也必须能写
U5="$T/etc/user5.conf"
printf '# smartroute 用户配置（优先级高于 /etc/smartroute.conf）\n' > "$U5"
{ mksr "$U5"; echo 'conf_set_kv MODE speed; echo "RC=$?"'; } > "$T/run5.sh"
o5="$(bash "$T/run5.sh" 2>&1)"
echo "$o5" | grep -q "RC=0" && ok "仅含注释的配置也能写入" || bad "仅注释的配置失败: $o5"
grep -q "^MODE=speed$" "$U5" && ok "注释行被保留" || bad "注释行丢了"
[ "$(grep -c '^#' "$U5")" = "1" ] && ok "注释行数量正确" || bad "注释行数量不对"

echo ""
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

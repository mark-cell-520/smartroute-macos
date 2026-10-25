#!/bin/bash
# 复现脚本（审计用）：_conf_set 少了 list 两侧的空格 → 用户的 SPEED_TEST_URL 被静默顶掉
#
# 结论（待验证）：
#   smartroute.sh:293-298 的 _conf_set 写的是
#       case "${_CONF_SET_KEYS:-}" in *" $1 "*) ...
#   少了模式匹配必需的 `case " $list "` 里的**外层空格**（项目里其它 5 处
#   同类判断都写了，见 VALID_KEYS/PROBE_TARGETS 去重/wifi_preferred_candidates）。
#   于是 _CONF_SET_KEYS 里只有它一个键、或它是最后一个键时永远返回否。
#   后果：measure_throughput 走 else 分支，用脚本默认的 SPEED_TEST_URLS 列表，
#   用户配的 SPEED_TEST_URL 一次都不会被请求——正是 5758-5764 行注释里
#   说"绝不能让它发生"的那个后果（他改了配置、重启守护进程、发现测速
#   结果毫无变化，会以为工具没生效）。
#
# 附带：即便修好 _conf_set，写在系统级 /etc/smartroute.conf 里的值仍然
#   不进 _CONF_SET_KEYS（/etc 是 `.` source 的，不过 conf_parse_file），
#   而 README 恰恰教用户往 /etc 里写配置。
#
# 运行: bash tests/repro_conf_set_keys.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

SRC=smartroute.sh
T="$(mktemp -d /tmp/sr_csk.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/etc" "$T/state"

cat > "$T/bin/ifconfig" <<'EOF'
#!/bin/bash
[ "$1" = "en1" ] && { echo "en1: flags=8863<UP> mtu 1500"; echo "	inet 192.168.1.5 netmask 0xffffff00"; exit 0; }
exec /sbin/ifconfig "$@"
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
for a in "$@"; do case "$a" in http*) printf '%s\n' "$a" >> "$MOCK_LOG" ;; esac; done
echo "1234567"
exit 0
EOF
chmod +x "$T/bin/"*

sed -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log\"|" \
    -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/lock\"|" \
    -e "s|^USER_CONF=.*|USER_CONF=\"$T/etc/user.conf\"|" \
    -e "s|^CONF=.*|CONF=\"$T/etc/smartroute.conf\"|" \
    -e "s|^RULES_FILE=.*|RULES_FILE=\"$T/etc/smartroute.rules\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"

cat > "$T/drv.sh" <<'EOF'
#!/bin/bash
export PATH="$MOCK_BIN:$PATH"
export MOCK_LOG
. "$MOCK_SR"
ACTIVE_WIFI_DEV=en1
eval "$SR_CODE"
EOF
chmod +x "$T/drv.sh"
# 另存一份"把 _conf_set 修好"的副本，用来证明 /etc 那一半是独立问题
sed 's|case "${_CONF_SET_KEYS:-}" in|case " ${_CONF_SET_KEYS:-} " in|' "$T/sr.sh" > "$T/sr_fixed.sh"
grep -q 'case " ${_CONF_SET_KEYS:-} " in' "$T/sr_fixed.sh" \
    || { echo "补丁没打上，退出"; exit 1; }
# $1=要跑的代码；$2=用户级配置内容；$3=系统级配置内容；$4=用哪个副本（默认原版）
go() {
    printf '%s' "${2:-}" > "$T/etc/user.conf"
    printf '%s' "${3:-}" > "$T/etc/smartroute.conf"
    : > "$T/urls.txt"
    MOCK_BIN="$T/bin" MOCK_SR="${4:-$T/sr.sh}" MOCK_LOG="$T/urls.txt" SR_CODE="$1" bash "$T/drv.sh" 2>&1
}
MINE='http://my-mirror.local/big.bin'
DEF='https://mirrors.aliyun.com/debian/dists/stable/main/binary-amd64/Packages.gz'

echo "=== 0. _conf_set 的匹配语义（根因）==="
go '_CONF_SET_KEYS="${_CONF_SET_KEYS:-}"; for lst in "SPEED_TEST_URL" "SPEED_TEST_URL NOTIFY" "NOTIFY SPEED_TEST_URL"; do
       _CONF_SET_KEYS="$lst"; _conf_set SPEED_TEST_URL && r=是 || r=否
       printf "    _CONF_SET_KEYS=[%-26s] _conf_set SPEED_TEST_URL -> %s\n" "$lst" "$r"
     done'
[ "$(go '_CONF_SET_KEYS="SPEED_TEST_URL"; _conf_set SPEED_TEST_URL && echo Y || echo N')" = "N" ] \
    && bad "只有一个键时 _conf_set 返回否（漏了 list 两侧空格）" || ok "单键也能匹配"

echo
echo "=== 1. 用户级配置里只写 SPEED_TEST_URL 一项（最常见）==="
out="$(go "measure_throughput en1 2" "SPEED_TEST_URL=$MINE")"
printf '    真正请求的地址: %s\n' "$(sort -u "$T/urls.txt" | tr '\n' ' ')"
grep -qx "$MINE" "$T/urls.txt" && ok "用了用户配的地址" \
    || bad "用的是脚本默认列表，用户配的 $MINE 一次都没被请求"

echo
echo "=== 2. 修好 _conf_set 之后（补丁副本），用户级配置立刻恢复 ==="
out="$(go "measure_throughput en1 2" "SPEED_TEST_URL=$MINE" "" "$T/sr_fixed.sh")"
printf '    真正请求的地址: %s\n' "$(sort -u "$T/urls.txt" | tr '\n' ' ')"
grep -qx "$MINE" "$T/urls.txt" && ok "补上两侧空格后，用户级配置的值被采用了（证明根因就是这里）" \
    || bad "补了空格还是没用上——根因判断错了"

echo
echo "=== 3. 同样用补丁副本，值写进 /etc/smartroute.conf（README 教用户这么做）==="
out="$(go "measure_throughput en1 2" "" "SPEED_TEST_URL=$MINE" "$T/sr_fixed.sh")"
printf '    真正请求的地址: %s\n' "$(sort -u "$T/urls.txt" | tr '\n' ' ')"
grep -qx "$MINE" "$T/urls.txt" && ok "系统级配置里的值被采用" \
    || bad "即便 _conf_set 修好，/etc 里的值仍然不进 _CONF_SET_KEYS（/etc 走 source，不过 conf_parse_file）"

echo
echo "=== 4. 用户看到的现象：config 同屏自相矛盾 ==="
go 'printf "    当前生效 SPEED_TEST_URL = %s\n" "$SPEED_TEST_URL"
   printf "    配置文件 %s 里写的是:\n" "$CONF"; sed "s/^/      /" "$CONF"
   measure_throughput en1 2 >/dev/null
   echo "    → 而守护进程实际请求的地址是:"
   sort -u "$MOCK_LOG" | sed "s/^/      /"' "" "SPEED_TEST_URL=$MINE"

echo
echo "结果: $PASS 通过, $FAIL 失败"

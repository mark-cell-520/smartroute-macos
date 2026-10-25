#!/bin/bash
# 复现脚本（审计用）：SPEED_TEST_URL / SPEED_TEST_URLS 放过"光有协议头"的值
#
# 结论（待验证）：smartroute.sh:173 与 176-182 写成
#       SPEED_TEST_URL) case "$val" in http://*|https://*) [ -n "$val" ] || return 1 ;; *) return 1 ;; esac ;;
#   `[ -n "$val" ]` 放在**模式已经匹配之后**，此时 $val 必然非空，是个永远
#   为真的死判断。原意（见注释与 App 侧）是拒掉 "http://" 这种半截值。
#   SPEED_TEST_URLS 的循环里同一个写法，同样放过。
#   于是 bash 收、App 拒（NetworkModel.swift:854-870 用 prefix.count 判），
#   漂移方向和 mock_conf_drift.sh 盯的方向正好相反，所以没被测出来。
#
# 后果：`smartroute set SPEED_TEST_URL http://` 报"已设置"，
# 之后每一轮测速都拿 "http://" 去打 curl，全部失败 → 网速优先模式静默失灵。
#
# 运行: bash tests/repro_conf_bare_scheme.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d /tmp/sr_bs.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/etc" "$T/state"
sed -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log\"|" \
    -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/lock\"|" \
    -e "s|^USER_CONF=.*|USER_CONF=\"$T/etc/user.conf\"|" \
    -e "s|^CONF=.*|CONF=\"$T/etc/system.conf\"|" \
    -e "s|^RULES_FILE=.*|RULES_FILE=\"$T/etc/smartroute.rules\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" smartroute.sh \
    | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"

# 代码统一走环境变量 + 驱动脚本，避开嵌套引号
cat > "$T/drv.sh" <<'EOF'
#!/bin/bash
export PATH="$MOCK_BIN:$PATH"; export MOCK_LOG
. "$MOCK_SR"
ACTIVE_WIFI_DEV=en1
eval "$SR_CODE"
EOF
chmod +x "$T/drv.sh"
run() { MOCK_BIN="$T/bin" MOCK_SR="$T/sr.sh" MOCK_LOG="$T/urls.txt" SR_CODE="$1" bash "$T/drv.sh" 2>&1; }

echo "=== 1. bash 侧：半截 URL 全收 ==="
run 'for v in "http://" "https://" "http://x"; do
       conf_value_ok SPEED_TEST_URL "$v" && r=收 || r=拒
       printf "    SPEED_TEST_URL   [%-10s] -> %s\n" "$v" "$r"
     done
     for v in "http://" "http://a"; do
       conf_value_ok SPEED_TEST_URLS "$v" && r=收 || r=拒
       printf "    SPEED_TEST_URLS  [%-10s] -> %s\n" "$v" "$r"
     done'
[ "$(run 'conf_value_ok SPEED_TEST_URL "http://" && echo Y || echo N')" = "N" ] \
    && ok "SPEED_TEST_URL=http:// 被拒" \
    || bad "SPEED_TEST_URL=http:// 被收下（半截值，curl 只会失败）"
[ "$(run 'conf_value_ok SPEED_TEST_URLS "http://" && echo Y || echo N')" = "N" ] \
    && ok "SPEED_TEST_URLS=http:// 被拒" \
    || bad "SPEED_TEST_URLS=http:// 被收下"

echo
echo "=== 2. App 侧（Swift sanitizeConf）对同一批键：拒 ==="
cat > "$T/swift_probe.swift" <<'SWIFT'
import Foundation
func appOk(_ key: String, _ val: String) -> Bool {
    switch key {
    case "SPEED_TEST_URL":
        if let prefix = val.hasPrefix("https://") ? "https://"
                      : val.hasPrefix("http://")  ? "http://"  : nil {
            return val.count > prefix.count
        }
        return false
    case "SPEED_TEST_URLS":
        let parts = val.split(separator: " ").map(String.init)
        return !parts.isEmpty && parts.allSatisfy {
            $0.hasPrefix("https://") && $0.count > "https://".count
                || $0.hasPrefix("http://")  && $0.count > "http://".count
        }
    default: return true
    }
}
for kv in CommandLine.arguments.dropFirst() {
    let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
    print("\(p[0])=\(p[1]) app=\(appOk(p[0], p[1]) ? "收" : "拒")")
}
SWIFT
swiftc -O "$T/swift_probe.swift" -o "$T/swift_probe" 2>&1 | head -3
for kv in "SPEED_TEST_URL=http://" "SPEED_TEST_URLS=http://" "SPEED_TEST_URL=http://x"; do
    b=拒; [ "$(run "conf_value_ok ${kv%%=*} '${kv#*=}' && echo Y || echo N")" = "Y" ] && b=收
    a="$("$T/swift_probe" "$kv" | sed 's/.*app=//')"
    printf '    %-26s bash=%s App=%s\n' "$kv" "$b" "$a"
    [ "$b" = "$a" ] || bad "漂移: $kv bash=$b App=$a"
done

echo
echo "=== 3. smartroute set 的现场：假成功 ==="
: > "$T/etc/user.conf"; : > "$T/etc/system.conf"
out="$(run 'LOG_FILE="'"$T"'/log"; STATE_FILE="'"$T"'/state/state"; LOCK_DIR="'"$T"'/run/lock"
    USER_CONF="'"$T"'/etc/user.conf"; CONF="'"$T"'/etc/system.conf"
    cmd_set SPEED_TEST_URL "http://"')"
printf '%s\n' "$out" | sed 's/^/    /'
printf '    写进去的内容: %s\n' "$(cat "$T/etc/user.conf")"
printf '%s' "$out" | grep -q '已设置' \
    && bad "报'已设置'，但写进去的是个 curl 永远连不上的值" || ok "没有假成功"

echo
echo "=== 4. 后果：网速优先模式的测速全部失败 ==="
cat > "$T/bin/ifconfig" <<'EOF'
#!/bin/bash
[ "$1" = "en1" ] && { echo "en1: flags=8863<UP> mtu 1500"; echo "	inet 192.168.1.5 netmask 0xffffff00"; exit 0; }
exec /sbin/ifconfig "$@"
EOF
# 真 curl 拿 "http://" 会直接失败（speed_download 打 0、退出码非 0）
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
printf 'curl 收到: [%s]\n' "$url" >> "$MOCK_LOG"
case "$url" in http://|https://) echo "0"; exit 6 ;; esac
echo "1234567"; exit 0
EOF
chmod +x "$T/bin/"*
printf 'SPEED_TEST_URLS=http://\n' > "$T/etc/user.conf"
: > "$T/etc/system.conf"; : > "$T/urls.txt"
out="$(run 'v="$(measure_throughput en1 2)"; echo "    measure_throughput 返回: [${v:-空}]"')"
printf '%s\n' "$out"
printf '    curl 实际收到的地址: %s\n' "$(sort -u "$T/urls.txt" | tr '\n' ' ')"
grep -q 'curl 收到: \[http://\]' "$T/urls.txt" \
    && bad "测速每轮都拿 http:// 去打 curl，永远失败（网速优先静默失灵）" || ok "没有拿半截值去打 curl"

echo
echo "=== 5. 附带：错误提示与真实规则相反 ==="
out="$(run 'cmd_set SPEED_TEST_URL "speed.cloudflare.com/x"' 2>&1 | head -1)"
printf '    set SPEED_TEST_URL speed.cloudflare.com/x -> %s\n' "$out"
printf '%s' "$out" | grep -q '不能为空' \
    && bad "真实原因是'必须是 http/https 地址'，提示却说'不能为空'" || ok "提示准确"

echo
echo "结果: $PASS 通过, $FAIL 失败"

echo
echo "=== 6. 附带：KEY VALUE 形式传空值，报的是"无法识别: KEY" ==="
: > "$T/etc/user.conf"; : > "$T/etc/system.conf"
out="$(run 'cmd_set NOTIFY ""' 2>&1 | head -2)"
printf '%s\n' "$out" | sed 's/^/    /'
printf '%s' "$out" | grep -q '无法识别: NOTIFY' \
    && bad "NOTIFY 是合法键，却被告知"无法识别"（cmd_set 的 KEY VALUE 分支要求 \$2 非空）" || ok "报错准确"
out2="$(run 'cmd_set "NOTIFY="' 2>&1 | head -1)"
printf '    对照 set NOTIFY= -> %s\n' "$out2"

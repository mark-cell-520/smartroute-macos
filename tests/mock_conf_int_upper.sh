#!/bin/bash
# 复现脚本（审计用）：整数键的"86400 上界"只在 bash 侧存在
#
# 三件事一起证明：
#   1) bash 的 conf_value_ok 对整数键有 86400 上界（smartroute.sh:152-164）
#   2) App 的 sanitizeConf 对同一批键只判"全是数字"（NetworkModel.swift:842），
#      没有上界 —— 于是 App 收得进、守护进程静默丢弃
#   3) conf_value_hint 对这批键的说法是"必须是非负整数"，与实际的
#      "≤86400"相反 —— smartroute set 拒绝一个合法写法时给的理由是错的
#
# 运行: bash tests/repro_conf_int_upper.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d /tmp/sr_int.XXXXXX)"
trap 'rm -rf "$T"' EXIT
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
. "$T/sr.sh"

echo "=== 1. bash 侧：整数键超过 86400 一律拒（且提示与真实规则相反）==="
printf '  %-22s %-10s %s\n' "键=值" "conf_value_ok" "conf_value_hint 的说法"
for kv in "NC_TIMEOUT=100000" "SPEED_RECHECK=604800" "COOLDOWN=90000" "OK_N=1000000" "NC_TIMEOUT=30"; do
    k="${kv%%=*}"; v="${kv#*=}"
    if conf_value_ok "$k" "$v"; then r="收"; else r="拒"; fi
    h="$(conf_value_hint "$k")"
    printf '  %-22s %-10s %s\n' "$kv" "$r" "$h"
done
conf_value_ok SPEED_RECHECK 604800 && bad "604800 被收下（与预期不符）" \
    || ok "bash 拒 SPEED_RECHECK=604800（一周），规则是 ≤86400"
[ "$(conf_value_hint SPEED_RECHECK)" = "SPEED_RECHECK 必须是非负整数" ] \
    && bad "提示说'非负整数'，真实规则是'≤86400'——用户被引导去改一个改不动的值" \
    || ok "提示已说明上界"

echo
echo "=== 2. smartroute set 的现场：理由与事实相反 ==="
out="$(cmd_set SPEED_RECHECK 604800 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
printf '    (退出码 %s)\n' "$rc"
printf '%s' "$out" | grep -q '必须是非负整数' \
    && bad "提示要求'非负整数'，而 604800 正是非负整数——用户无从知道卡在上界" \
    || ok "提示没有误导"

echo
echo "=== 3. App 侧（Swift sanitizeConf）对同一批键的规则 ==="
# 直接复刻 NetworkModel.swift 的整数分支判定式，键表与上界都从生成文件里取真值
cat > "$T/main.swift" <<SWIFT
import Foundation
let intKeys: Set<String> = [
$(sed -n '/static let intKeys/,/]/p' SmartRouteApp/GeneratedConfigKeys.swift | grep -o '"[A-Z_]*"' | tr -d '"' | sed 's/.*/    "&",/')
]
let intBound = GeneratedConfigKeys.intBound
func appOk(_ key: String, _ val: String) -> Bool {
    switch key {
    case _ where intKeys.contains(key):
        return !val.isEmpty && val.allSatisfy { \$0.isNumber }
            && (Int(val) ?? Int.max) <= intBound
    default: return true
    }
}
for kv in CommandLine.arguments.dropFirst() {
    let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
    print("\(p[0])=\(p[1]) app=\(appOk(p[0], p[1]) ? "收" : "拒")")
}
SWIFT
swiftc -O "$T/main.swift" SmartRouteApp/GeneratedConfigKeys.swift \
      -o "$T/swift_probe" 2>&1 | head -5
for kv in "NC_TIMEOUT=100000" "SPEED_RECHECK=604800" "COOLDOWN=90000" "OK_N=1000000" "NC_TIMEOUT=30"; do
    k="${kv%%=*}"; v="${kv#*=}"
    b="拒"; conf_value_ok "$k" "$v" && b="收"
    a="$("$T/swift_probe" "$kv" | sed 's/.*app=//')"
    printf '  %-24s bash=%s  App=%s\n' "$kv" "$b" "$a"
    [ "$b" = "$a" ] || bad "漂移: $kv bash=$b 而 App=$a"
done

echo
echo "=== 4. 漂移的用户后果：App 说已导入，守护进程静默丢弃 ==="
printf 'NC_TIMEOUT=100000\nMODE=wifi\n' > "$T/user.conf"
chmod 644 "$T/user.conf"
( USER_CONF="$T/user.conf"; export USER_CONF
  # 只跑解析，不跑入口
  bash -c ". '$T/sr.sh'; NC_TIMEOUT=2; conf_parse_file '$T/user.conf'; echo \"    解析后 NC_TIMEOUT=\$NC_TIMEOUT MODE=\$MODE\"" )
echo "    （配置里写的是 NC_TIMEOUT=100000，上面这行是守护进程真正看到的值）"
out="$(bash -c ". '$T/sr.sh'; NC_TIMEOUT=2; conf_parse_file '$T/user.conf'; echo \$NC_TIMEOUT")"
[ "$out" = "2" ] && bad "NC_TIMEOUT=100000 被静默丢弃，回落默认 2，无任何提示" \
                   || ok "值被保留了"

echo
echo "结果: $PASS 通过, $FAIL 失败"

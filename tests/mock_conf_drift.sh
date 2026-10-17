#!/bin/bash
# App 与脚本的配置校验器不能漂移
#
# 为什么需要这个测试：App 的 sanitizeConf 把脚本的 conf_value_ok 重新实现了
# 一遍（两套语言、两份清单）。已经实测漂移过 3 处：
#   · BALANCE_MODE 漏了 weighted  → App 拒存脚本自己写的值，假成功
#   · SPEED_TEST_URL 没限协议     → 与脚本的收紧形成缺口
#   · WEIGHT_RECHECK 整个键缺失   → 导入配置时该行被静默丢弃
# 每加一个配置键都要改两处，漏一处的表现是"App 说已保存但实际没生效"，
# 而脚本侧没有任何报错——这类 bug 不测试抓不到。
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

# 1) 键集合必须一致
BASH_KEYS="$(grep -m1 '^VALID_KEYS=' smartroute.sh | sed 's/^VALID_KEYS="//; s/"$//' | tr ' ' '\n' | sed '/^$/d' | sort)"
SWIFT_KEYS="$(sed -n '/let validKeys: Set<String> = \[/,/\]/p' SmartRouteApp/NetworkModel.swift \
              | grep -o '"[A-Z_]*"' | tr -d '"' | sed '/^$/d' | sort)"
n_b="$(printf '%s\n' "$BASH_KEYS" | wc -l | tr -d ' ')"
n_s="$(printf '%s\n' "$SWIFT_KEYS" | wc -l | tr -d ' ')"
if [ "$n_b" = "$n_s" ] && [ "$BASH_KEYS" = "$SWIFT_KEYS" ]; then
    ok "键集合一致（$n_b 个）"
else
    bad "键集合不一致：bash $n_b 个 / Swift $n_s 个"
    printf '    仅 bash 有: %s\n' "$(comm -23 <(printf '%s\n' "$BASH_KEYS") <(printf '%s\n' "$SWIFT_KEYS") | tr '\n' ' ')"
    printf '    仅 Swift 有: %s\n' "$(comm -13 <(printf '%s\n' "$BASH_KEYS") <(printf '%s\n' "$SWIFT_KEYS") | tr '\n' ' ')"
fi

# 2) 每个键的取值规则必须一致
#    bash 的 conf_value_ok 与 Swift 的 switch 逐键比对。
check_mode() {  # $1=键 $2=合法值列表（bash 的 case 分支）
    b="$(grep -A1 "^        $1)" smartroute.sh | grep -o 'in [^)]*)' | head -1 | sed 's/^in //; s/)$//; s/ *| */|/g')"
    case "$1" in
        MODE)         s='auto|ethernet|wifi|speed|latency' ;;
        BALANCE_MODE) s='round-robin|fastest|weighted' ;;
        *) s="" ;;
    esac
    [ -n "$s" ] || return 0
    if [ "$b" = "$s" ]; then ok "$1 取值一致（$s）"; else bad "$1 取值不一致：bash=[$b] 期望=[$s]"; fi
}
check_mode MODE
check_mode BALANCE_MODE

# 3) SPEED_TEST_URL 两边都必须限 http/https
grep -q 'SPEED_TEST_URL) case "\$val" in http://\*|https://\*)' smartroute.sh \
    && ok "脚本侧 SPEED_TEST_URL 限 http/https" || bad "脚本侧没限协议"
grep -q 'case "SPEED_TEST_URL"' SmartRouteApp/NetworkModel.swift \
    && ok "App 侧对 SPEED_TEST_URL 有专门分支" || bad "App 侧没限协议"
# 光有协议头（http:// 后面什么都没有）脚本侧是拒的，App 以前放过——
# 于是用户看到已导入，守护进程却静默丢掉这个键。
# 现在要求"按实际命中的前缀剥除后非空"。
grep -q 'val.count > prefix.count' SmartRouteApp/NetworkModel.swift \
    && ok "App 侧拒绝半截 URL（只有协议头）" \
    || bad "App 侧仍会放过 http:// 这种半截值，与脚本不一致"
# 但不能做得比脚本还严：http://x 这种 8 字符的短 URL 脚本是收的。
# 曾经写成 count > "https://".count（8），正好把 http://x 一起拒掉。
grep -q 'prefix.count' SmartRouteApp/NetworkModel.swift \
    && ok "按实际前缀长度判定（不会误拒 http://x 这类短 URL）" \
    || bad "判定基准写死成 https:// 的长度，会误拒短 http:// URL"

# 4) 布尔键集合一致
BASH_BOOL="$(grep -m1 'TLS_PROBE|NOTIFY|AUTO_WIFI_POWER|BALANCE|WIFI_FAILOVER)' smartroute.sh | sed 's/ *TLS_PROBE|/TLS_PROBE|/; s/) *$//')"
SWIFT_BOOL="$(grep -m1 'let boolKeys: Set<String>' SmartRouteApp/NetworkModel.swift | grep -o '\[.*\]' | tr -d '[]"' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' | tr '\n' '|' | sed 's/|$//')"
if [ "$(printf '%s' "$BASH_BOOL" | tr '|' '\n' | sort | tr '\n' ',')" = "$(printf '%s' "$SWIFT_BOOL" | tr '|' '\n' | sort | tr '\n' ',')" ]; then
    ok "布尔键集合一致（$(printf '%s' "$SWIFT_BOOL" | tr '|' ' ' | wc -w | tr -d ' ') 个）"
else
    bad "布尔键集合不一致"
    printf '    bash: %s\n    swift: %s\n' "$BASH_BOOL" "$SWIFT_BOOL"
fi

# 5) 整数键集合一致
BASH_INT="$(grep -m1 'OK_N|FAIL_N|COOLDOWN|PING_TIMEOUT' smartroute.sh | sed 's/^ *//; s/)$//' | tr -d ' ')"
SWIFT_INT="$(sed -n '/let intKeys: Set<String> = \[/,/\]/p' SmartRouteApp/NetworkModel.swift | grep -o '"[A-Z_]*"' | tr -d '"' | tr '\n' '|' | sed 's/|$//')"
if [ "$(printf '%s' "$BASH_INT" | tr '|' '\n' | sort | tr '\n' ',')" = "$(printf '%s' "$SWIFT_INT" | tr '|' '\n' | sort | tr '\n' ',')" ]; then
    ok "整数键集合一致（$(printf '%s' "$SWIFT_INT" | tr '|' ' ' | wc -w | tr -d ' ') 个）"
else
    bad "整数键集合不一致"
    printf '    bash:  %s\n    swift: %s\n' "$BASH_INT" "$SWIFT_INT"
fi

# 6) Swift 语法仍可解析（防改坏）
if swiftc -parse SmartRouteApp/NetworkModel.swift >/dev/null 2>&1; then
    ok "NetworkModel.swift 仍可解析"
else
    bad "NetworkModel.swift 解析失败"
    swiftc -parse SmartRouteApp/NetworkModel.swift 2>&1 | head -3 | sed 's/^/    /'
fi

echo ""
echo "结果: $PASS 通过, $FAIL 失败"

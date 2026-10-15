#!/bin/bash
# 测试 App 的 Wi-Fi 解析逻辑 —— 拿真实脚本输出喂给真实的 Swift 解析代码
#
# 为什么值得单独立一个测试：
#   以前解析逻辑混在 NetworkModel 里，从没被验证过。结果
#   `String(t[r])` 拿到的是整个正则匹配而不是捕获组，用户在 App 里点"连接"
#   时，真的把 "1. CZ-305"（带序号前缀）当成 SSID 发给了 networksetup，
#   于是必然连不上。这类 bug 在 bash 测试里发现不了，因为解析在 Swift 侧。
#
# 做法：把 SmartRouteApp/WifiParsing.swift 编译成一个小二进制，
# 喂给它 `smartroute wifi list --raw` / `wifi current` 的真实输出，检查结果。
#
# 运行: bash tests/mock_wifi_parse.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d /tmp/sr_wifiparse.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# ---------- 编译被测的解析代码 ----------
cat > "$T/main.swift" <<'EOF'
import Foundation
// 命令：list <文件>   → 一行一个 SSID
//       current <文本> → rssi|channel|bars
let args = CommandLine.arguments
switch args[1] {
case "list":
    let text = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? ""
    print(WifiParsing.savedNetworks(text).joined(separator: "\n"))
case "current":
    if let r = WifiParsing.currentSignal(args[2]) {
        print("\(r.rssi)|\(r.channel)|\(r.bars)")
    } else {
        print("nil")
    }
default:
    print("unknown")
}
EOF

if ! swiftc -O -module-cache-path "$T/mc" \
        "$T/main.swift" SmartRouteApp/WifiParsing.swift \
        -o "$T/parse" 2>"$T/cc.log"; then
    echo "编译失败："; cat "$T/cc.log"; exit 1
fi
ok "解析代码编译通过"

echo "=== 1. wifi list --raw：一行一个 SSID ==="
bash smartroute.sh wifi list --raw > "$T/raw.txt" 2>/dev/null
out="$("$T/parse" list "$T/raw.txt")"
n="$(printf '%s\n' "$out" | grep -c .)"
[ "$n" -ge 1 ] && ok "解析出 $n 个网络" || bad "一个都没解析出来"
# 关键：不能带序号前缀（这就是用户碰到的 bug）
if printf '%s' "$out" | grep -qE '^[0-9]+\. '; then
    bad "SSID 里混进了序号前缀：$(printf '%s' "$out" | head -1)"
else
    ok "SSID 干净，无序号前缀"
fi
# 每个解析出来的 SSID 必须原样出现在 --raw 输出里
first_raw="$(grep -m1 . "$T/raw.txt")"
first_parsed="$(printf '%s\n' "$out" | head -1)"
[ "$first_raw" = "$first_parsed" ] && ok "与 --raw 首行一致：[$first_parsed]" || bad "期望 [$first_raw] 得到 [$first_parsed]"

echo "=== 2. 刁钻 SSID：名字本身带序号和空格 ==="
# SSID 完全可以叫 "1. CZ-305" 或 "2. 带空格"。用带序号的格式解析就会剥错，
# 所以脚本给了 --raw。这里验证 --raw + 解析能原样保住这些名字。
printf '1. CZ-305\n2. 带空格\n\n普通名字\n' > "$T/tricky.txt"
out="$("$T/parse" list "$T/tricky.txt")"
want=$'1. CZ-305\n2. 带空格\n普通名字'
[ "$out" = "$want" ] && ok "序号样子的 SSID 原样保留（空行被正确丢掉）" || bad "期望 [$want] 得到 [$out]"

echo "=== 3. wifi current：rssi / channel / bars ==="
bash smartroute.sh wifi current > "$T/cur.txt" 2>/dev/null
curline="$(cat "$T/cur.txt")"
echo "  真实输出: $curline"
out="$("$T/parse" current "$curline")"
echo "  解析结果: $out"
rssi="${out%%|*}"
case "$rssi" in
    -[0-9]|-[0-9][0-9]|[0-9]) ok "rssi 是纯数字：$rssi" ;;
    *) bad "rssi 不是纯数字（可能把\"信号\"和\"dBm\"也吞进来了）：[$rssi]" ;;
esac
if printf '%s' "$out" | grep -q '|.*|'; then
    ch="$(printf '%s' "$out" | cut -d'|' -f2)"
    case "$ch" in
        [0-9]|[0-9][0-9]*) ok "channel 是数字：$ch" ;;
        *) bad "channel 解析异常：[$ch]" ;;
    esac
    bars="$(printf '%s' "$out" | cut -d'|' -f3)"
    case "$bars" in
        1|2|3|4) ok "bars 在 1~4：$bars" ;;
        *) bad "bars 解析异常：[$bars]" ;;
    esac
fi

echo "=== 4. 边界：读不到信号时返回 nil，不是崩溃 ==="
for txt in "" "You are not associated with an AirPort network." "Wi-Fi en1  信号  dBm  信道"; do
    out="$("$T/parse" current "$txt")"
    [ "$out" = "nil" ] && ok "异常输入安全返回 nil：[${txt:0:24}]" || bad "异常输入得到 [$out]"
done

echo "=== 5. 信道缺失时给占位符，不崩 ==="
out="$("$T/parse" current "Wi-Fi en1  信号 -70 dBm（2/4 格）")"
[ "$out" = "-70|?|2" ] && ok "缺信道时 channel=? ：$out" || bad "得到 $out"

echo "=== 6. 回归：这就是用户碰到的那个 bug ==="
# 旧的错误写法 String(t[r]) 会返回整个匹配 "1. CZ-305"
if printf '%s' "$out" | grep -q "信号"; then
    bad "解析结果里含\"信号\"二字——又回到整个匹配的 bug 了"
else
    ok "解析结果不含\"信号\"/\"dBm\"等字样（确认取的是捕获组）"
fi

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

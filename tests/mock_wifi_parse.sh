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
SRC="$PWD/smartroute.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d /tmp/sr_wifiparse.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# ---------- 编译被测的解析代码 ----------
cat > "$T/main.swift" <<'EOF'
import Foundation
// 命令：list <文件>      → 一行一个 SSID
//       current <文本>   → rssi|channel|bars
//       nearby <文件>    → 每条 "name|rssi|bars|channel"
//       unknown <文件>   → 未能确认的个数
let args = CommandLine.arguments
switch args[1] {
case "list":
    let text = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? ""
    print(WifiParsing.savedNetworks(text).joined(separator: "\n"))
case "current":
    // 文件里可能是人类格式，也可能是一行 key=value（--raw）
    let text = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? args[2]
    if let r = WifiParsing.currentSignal(text) {
        print("\(r.rssi)|\(r.channel)|\(r.bars)")
    } else {
        print("nil")
    }
case "rate":
    let text = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? args[2]
    print(WifiParsing.capture(text, pattern: "rate=([0-9]+)") ?? "nil")
case "noise":
    let text = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? args[2]
    print(WifiParsing.capture(text, pattern: "noise=(-?[0-9]+)") ?? "nil")
case "nearby":
    let text = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? ""
    for n in WifiParsing.nearbyNetworks(text) {
        print("\(n.name)|\(n.rssi)|\(n.bars)|\(n.channel)")
    }
    print("count=\(WifiParsing.nearbyNetworks(text).count)")
case "unknown":
    let text = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? ""
    print(WifiParsing.scanUnknownCount(text).map(String.init) ?? "nil")
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

echo "=== 6b. wifi current --raw：一次调用拿全（App 走这条） ==="
# 这条格式存在的理由：system_profiler 一次要约 1.7 秒，App 原来为了速率和噪声
# 去跑两次 status（各 1.8 秒），Wi-Fi 页刷新要 5 秒。
# pre.sh（入口前的纯函数段）必须在 if 外生成：下面的档位循环无条件执行，
# 而 /tmp/cur_raw.txt 不是每台机器都有——没有它时 pre.sh 从未被创建，
# 循环里 source 不存在的文件，7 个档位全假失败（2026-10-24 实测）。
awk '/^# ---------------- 入口 ----------------/{exit} {print}' "$SRC" > "$T/pre.sh"
if [ -s /tmp/cur_raw.txt ]; then
    echo "  真实输出: $(cat /tmp/cur_raw.txt)"
    out="$("$T/parse" current /tmp/cur_raw.txt)"
    echo "  解析: $out"
    case "$out" in
        -[0-9]*|[0-9]*) ok "raw 格式能解析出信号" ;;
        *) bad "raw 格式解析失败: $out" ;;
    esac
    # bars 必须和脚本的 wifi_bars 一致（同一个 dBm 必须得到同一个格数）。
    # 这条断言抓到一起真实的档位错位：脚本按 -5*/-4*→4、-6*→3、-7*→2 分档，
    # 而 Swift 那边原来是 -50~-59→3，导致 -52 dBm 在命令行显示 4 格、App 显示 3 格。
    rssi="${out%%|*}"
    want="$(bash -c ". '$T/pre.sh'; wifi_bars '$rssi'")"
    got="$(printf '%s' "$out" | cut -d'|' -f3)"
    [ "$want" = "$got" ] && ok "格数与脚本一致（$rssi dBm -> $got 格）" || bad "脚本算 $want 格，Swift 算 $got 格"
    out="$("$T/parse" rate /tmp/cur_raw.txt)"
    case "$out" in ''|nil) echo "  （本机无速率，跳过）" ;; *) ok "速率可解析: $out Mbps" ;; esac
    out="$("$T/parse" noise /tmp/cur_raw.txt)"
    case "$out" in ''|nil) echo "  （本机无噪声，跳过）" ;; *) ok "噪声可解析: $out dBm" ;; esac
fi
# 人类格式仍然要认（命令行输出没变）
out="$("$T/parse" current "Wi-Fi en1  信号 -70 dBm（2/4 格）  信道 44")"
[ "$out" = "-70|44|2" ] && ok "人类格式仍能解析" || bad "得到: $out"
# 只有 raw 格式时，中文字段缺失也不能崩
out="$("$T/parse" current "rssi=-52 channel=6 rate=432 noise=-96")"
[ "$out" = "-52|6|4" ] && ok "纯 key=value 也能解析（-52 是 4 格）" || bad "得到: $out"
# 逐个档位和脚本比对，防止再次错位
# 汇总行必须等循环真跑完再判——原来是循环后无条件 ok，7 个全失败也打印
# "全部一致"，输出自相矛盾，失败被一行 ✓ 盖掉。
_lv_bad=0
for dbm in -45 -52 -60 -65 -70 -75 -85; do
    want="$(bash -c ". '$T/pre.sh'; wifi_bars '$dbm'")"
    got="$("$T/parse" current "rssi=$dbm channel=6" | cut -d'|' -f3)"
    [ "$want" = "$got" ] || { _lv_bad=$((_lv_bad+1)); bad "档位不一致：$dbm dBm 脚本=$want Swift=$got"; }
done
[ "$_lv_bad" -eq 0 ] && ok "7 个档位全部与脚本一致" || bad "$_lv_bad/7 个档位与脚本不一致"

echo "=== 7. 附近网络：喂真实 scan 输出 ==="
if [ -s /tmp/real_scan.txt ]; then
    out="$("$T/parse" nearby /tmp/real_scan.txt)"
    echo "  真实输出解析结果:"; printf '%s\n' "$out" | sed 's/^/    /'
    cnt="$(printf '%s\n' "$out" | sed -n 's/^count=//p')"
    [ -n "$cnt" ] && [ "$cnt" -ge 1 ] && ok "解析出 $cnt 个附近网络" || bad "一个都没解析出来"
    # 关键：不能把"确认不在范围"里的网络也当成能连的
    if printf '%s' "$out" | grep -qE "^(m|405-2|A1234)\|"; then
        bad "把不在范围的网络也解析成附近了"
    else
        ok "没有混入"确认不在范围"那一段"
    fi
    # 每条的 rssi 必须是整数
    if printf '%s\n' "$out" | grep -v '^count=' | grep -qE '^[^|]+\|[^0-9-]'; then
        bad "rssi 不是数字"
    else
        ok "rssi 都是数字"
    fi
else
    echo "  （没有真实输出，跳过）"
fi

echo "=== 8. 附近网络：边界 ==="
# 只有标题没有条目
printf '在范围的已保存网络（按信号排序，越靠前越好）：\n\n确认不在范围的：\n' > "$T/n1.txt"
out="$("$T/parse" nearby "$T/n1.txt")"
[ "$out" = "count=0" ] && ok "空段落返回 0 条" || bad "得到: $out"
# 没有"在范围的"标题时不该乱抓
printf '确认不在范围的（旁边没有这些路由器，属正常）：\n  CZ-305\n' > "$T/n2.txt"
out="$("$T/parse" nearby "$T/n2.txt")"
[ "$out" = "count=0" ] && ok "没有标题时返回 0 条（不会误抓）" || bad "得到: $out"
# SSID 带空格：名字取到第一个空白为止，但 rssi/bars 仍要抓对
printf '在范围的：\n  A9 5G    -52 dBm（4/4 格）  信道 6\n' > "$T/n3.txt"
out="$("$T/parse" nearby "$T/n3.txt")"
printf '%s' "$out" | grep -q "A9|-52|4|6" && ok "带空格的 SSID 也能解析（名字到第一个空白）" || bad "得到: $out"
# 未能确认的个数
printf '有 3 个没能确认（系统扫描有冷却，不是故障），重试即可。\n' > "$T/n4.txt"
out="$("$T/parse" unknown "$T/n4.txt")"
[ "$out" = "3" ] && ok "未能确认个数可解析" || bad "得到: $out"
printf '没有这句\n' > "$T/n5.txt"
out="$("$T/parse" unknown "$T/n5.txt")"
[ "$out" = "nil" ] && ok "没有该句时返回 nil" || bad "得到: $out"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

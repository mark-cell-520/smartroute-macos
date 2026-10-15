#!/bin/bash
# 测试 Shell.quote + AppleScript 转义的往返正确性
#
# 为什么要测：Wi-Fi 名字里出现空格、单引号、双引号、$、反斜杠都很常见
# （"Bob's Cafe"、"My Home WiFi"、中文名）。这个工具有两层引号边界：
#   1) Swift 拼命令  → bash        用 Shell.quote() 包成单引号字面量
#   2) AppleScript   → do shell script  用 Privileged.execute 转义 \ 和 "
# 两层任何一层出错，表现都是"连不上那个网络"而且看不出原因。
#
# 这个测试不启动 App，直接把两层的转义逻辑在 bash 里复刻一遍，
# 验证最终 bash 拿到的参数与原始 SSID 完全一致。
#
# 运行: bash tests/mock_quote.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

# 复刻 Swift 侧 Shell.quote()
swift_quote() {
    # 先把 ' 换成 '\'' ，再把整体包进一对单引号
    local inner
    inner="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
    printf "'%s'" "$inner"
}

# 复刻 Swift 侧 Privileged.execute 的 AppleScript 转义（只转义 \ 和 "）
applescript_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# 把 AppleScript 的字符串字面量还原成它实际代表的命令文本
applescript_unescape() {
    printf '%s' "$1" | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}

T="$(mktemp -d /tmp/sr_quote.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# 假 networksetup：
#   · -setairportnetwork 把第 3 个参数（SSID）原样写文件 —— 这是被测的核心
#   · -listallhardwareports / -listnetworkserviceorder 让 find_active 能找到 en1
cat > "$T/bin/networksetup" <<'EOF'
#!/bin/bash
case "$1" in
    -setairportnetwork)
        printf '%s' "$3" > "$MOCK_OUT"; exit 0 ;;
    -listallhardwareports)
        printf 'Hardware Port: Wi-Fi\nDevice: en1\nEthernet Address: aa:bb\n\n'
        printf 'Hardware Port: Ethernet\nDevice: en0\nEthernet Address: cc:dd\n\n'
        exit 0 ;;
    -listnetworkserviceorder)
        printf '(1) Wi-Fi\n\t(Hardware Port: Wi-Fi, Device: en1)\n\n'
        printf '(2) Ethernet\n\t(Hardware Port: Ethernet, Device: en0)\n\n'
        exit 0 ;;
    -getairportpower) echo "Wi-Fi Power (en1): On"; exit 0 ;;
    -getinfo) echo "Router: 192.168.1.1"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/bin/networksetup"
# smartroute.sh 第 2 行会把自己的一套 PATH 写进去，把 mock 目录挤掉，
# 所以这里准备一份删掉那行的副本（跟其它 mock 测试同一个套路）
sed '\|^PATH=/usr/local/sbin:|d' smartroute.sh > "$T/sr.sh"

echo "=== 1. Shell.quote：单引号字面量能被 bash 还原 ==="
while IFS= read -r ssid; do
    [ -n "$ssid" ] || continue
    q="$(swift_quote "$ssid")"
    got="$(bash -c "printf '%s' $q")"
    if [ "$got" = "$ssid" ]; then
        ok "还原一致: [$ssid]"
    else
        bad "被改坏了: 期望 [$ssid] 得到 [$got]（quote 后是 $q）"
    fi
done <<'EOF'
My Home WiFi
Bob's Cafe
He said "hi"
back\slash
dollar$sign
中文网络名
a'b"c\d
EOF

echo "=== 2. 两层叠加：AppleScript 转义后再进 bash ==="
# 这是 App 里真实发生的链路：command → applescript_escape → 放进
# do shell script "..." → osascript 还原 → bash 执行
while IFS= read -r ssid; do
    [ -n "$ssid" ] || continue
    # 用工作区里的脚本（它才有 wifi 子命令），PATH 前面加 mock 目录让假
    # networksetup 生效。写死 /usr/local/bin/smartroute 会跑到旧版，报 usage。
    cmd="bash '$T/sr.sh' wifi join $(swift_quote "$ssid")"
    esc="$(applescript_escape "$cmd")"
    # osascript 会把 \" 还原成 "、\\ 还原成 \，这一步就是 applescript_unescape
    restored="$(applescript_unescape "$esc")"
    rm -f "$T/out"
    MOCK_OUT="$T/out" PATH="$T/bin:$PATH" bash -c "$restored" >/dev/null 2>&1
    got="$(cat "$T/out" 2>/dev/null)"
    if [ "$got" = "$ssid" ]; then
        ok "两层后仍一致: [$ssid]"
    else
        bad "两层后被改坏: 期望 [$ssid] 得到 [$got]"
    fi
done <<'EOF'
My Home WiFi
Bob's Cafe
He said "hi"
back\slash
中文网络名
EOF

echo "=== 3. AppleScript 源串本身必须是合法的（引号成对） ==="
for ssid in 'Bob'\''s Cafe' 'say "hi"' 'back\slash'; do
    cmd="'/usr/local/bin/smartroute' wifi join $(swift_quote "$ssid")"
    esc="$(applescript_escape "$cmd")"
    # AppleScript 里未转义的双引号必须是偶数个（成对）
    n=$(printf '%s' "$esc" | tr -cd '"' | wc -c | tr -d ' ')
    if [ $((n % 2)) -eq 0 ]; then
        ok "双引号成对（$n 个）: [$ssid]"
    else
        bad "双引号落单了，AppleScript 会语法错误: [$ssid]"
    fi
done

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]

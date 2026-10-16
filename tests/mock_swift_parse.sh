#!/bin/bash
# 编译并运行 Swift 纯解析函数单测（tests/main.swift）
#
# 为什么必须测：审计意见原话"Swift NetworkModel 的解析函数没有任何自动化测试，
# 唯一覆盖是 mock_wifi_parse（且只测脚本）"。这些函数是 App 显示一切数据的地基，
# 解析错界面就显示错，而界面是用户唯一能看到的东西。此前改 bug 全靠人眼点开 App 看。
#
# 编译方式：把生产源文件连同测试文件一起编成可执行文件。
#   - 排除 SmartRouteApp.swift（带 @main，会和测试的 main 冲突）
#   - 排除 make_icon.swift（独立命令行工具，自带 main）
#   - 排除 Views.swift / WifiView.swift（只含 View，且会拖进一堆 UI 依赖）
# 剩下 NetworkModel / WifiParsing / Shell / Privileged / ScriptLocator / Theme。
#
# 运行: bash tests/mock_swift_parse.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
T="$(mktemp -d /tmp/sr_swift.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# 与 build_release.sh 用同一套 glob 规则，避免两边漏文件
SRCS="$(ls SmartRouteApp/*.swift \
        | grep -v '/make_icon\.swift$' \
        | grep -v '/SmartRouteApp\.swift$' \
        | grep -v '/Views\.swift$' \
        | grep -v '/WifiView\.swift$' \
        | tr '\n' ' ')"

echo "==> 编译单测（$T/swift_test）"
if ! swiftc -O -swift-version 5 -module-cache-path "$T/mc" \
        -target "$(uname -m)-apple-macosx13.0" \
        -o "$T/swift_test" $SRCS tests/main.swift \
        -framework SwiftUI -framework AppKit -framework Combine >"$T/build.log" 2>&1; then
    echo "  XX 编译失败："
    head -20 "$T/build.log"
    exit 1
fi
ok_compile=1

out="$("$T/swift_test" 2>&1)"
rc=$?
printf '%s\n' "$out"

# 统计：测试文件里的 OK/XX 行
p=$(printf '%s' "$out" | grep -c '  OK ')
f=$(printf '%s' "$out" | grep -c '  XX ')
echo
echo "结果: $p 通过, $f 失败"
[ "$rc" -eq 0 ] && [ "$f" -eq 0 ]

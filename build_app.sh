#!/bin/bash
# 把 SmartRouteApp/ 编译打包成 SmartRoute.app（需要 Xcode 或 Command Line Tools）
set -e
cd "$(dirname "$0")"
# 版本号从 VERSION 文件读，和 build_release.sh / build_dmg.sh 同一来源。
# 以前这里硬编码 "2.2"，而那两个脚本读文件——改版本号时只改文件的话，
# build_app.sh 产出的 app 会停在旧版本，Info.plist 和 dist 目录名对不上，
# 而用户看到的是"设置里显示 2.1"这种没法自查的矛盾。
VERSION="$(cat VERSION 2>/dev/null | tr -d '[:space:]')"
[ -n "$VERSION" ] || { echo "错误：读不到 VERSION 文件" >&2; exit 1; }
APP="SmartRoute.app"

echo "==> 清理旧构建"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 生成应用图标（Swift 绘制 → icns）"
mkdir -p "$PWD/.build/module-cache"
ICON_TOOL="$PWD/.build/make_icon"
swiftc -O -o "$ICON_TOOL" SmartRouteApp/make_icon.swift \
    -module-cache-path "$PWD/.build/module-cache" 2>/dev/null || ICON_TOOL=""
if [ -n "$ICON_TOOL" ] && [ -x "$ICON_TOOL" ]; then
    for sz in 16 32 48 128 256 512 1024; do
        "$ICON_TOOL" "$PWD/.build/icon_$sz.png" "$sz" >/dev/null
    done
    python3 - "$PWD/.build" <<'PYEOF'
import struct, sys
d = sys.argv[1]
elems = [(b'is32', f'{d}/icon_16.png'), (b'il32', f'{d}/icon_32.png'),
         (b'ih32', f'{d}/icon_48.png'), (b'it32', f'{d}/icon_128.png'),
         (b'ic07', f'{d}/icon_128.png'), (b'ic08', f'{d}/icon_256.png'),
         (b'ic09', f'{d}/icon_512.png'), (b'ic10', f'{d}/icon_1024.png')]
body = b''
for t, f in elems:
    data = open(f, 'rb').read()
    body += t + struct.pack('>I', len(data) + 8) + data
open(f'{d}/AppIcon.icns', 'wb').write(b'icns' + struct.pack('>I', len(body) + 8) + body)
PYEOF
    cp "$PWD/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    echo "    图标已生成"
else
    echo "    警告: 图标生成失败（不影响功能）"
fi

# ⚠️ 这个脚本只编**主机架构**，产物不能直接发布。
# 以前 README/INSTALL 教用户用它打发布包，Intel 用户拿到的是 arm64-only，
# 一打开就是"已损坏"。发布必须用 build_release.sh（通用二进制 + 校验 + 打包），
# 需要 DMG 时再跑 build_dmg.sh。
echo "==> 注意：本脚本只编主机架构（$(uname -m)），仅用于本地开发调试"
echo "          发布请用: bash build_release.sh"

echo "==> 生成配置键白名单（从 smartroute.sh，杜绝 App/脚本清单漂移）"
# sanitizeConf 的键表曾经在 Swift 里手写，和 bash 的 conf_value_ok 漂移过四次，
# 每次都是"App 显示已导入、实际没生效"。现在 bash 是唯一事实源，每次构建前
# 重生——打包进的 App 永远和它自带的 smartroute.sh 一致。
# 仓库里那份提交版本由 tests/mock_conf_drift.sh 的 --check 盯着防腐烂。
python3 tools/gen_config_keys.py || { echo "错误：生成配置键白名单失败" >&2; exit 1; }

echo "==> 编译 Swift 源码（SwiftUI + AppKit）"
# 源码用 glob，不手写清单：手写过两份（本文件和 build_release.sh 各一份），
# 两次新增 .swift 都只改了一处，另一处漏掉直接编译失败。glob 从根上消除这个问题。
# make_icon.swift 排除掉——它是生成图标的独立命令行工具，自带 main，不能编进 App。
# 排除要按完整文件名匹配：grep -v 'make_icon.swift' 是子串匹配，
# 以后加个 my_make_icon.swift 之类的会被误排除，而且很难查。
SRCS="$(ls SmartRouteApp/*.swift | grep -v '/make_icon\.swift$' | tr '\n' ' ')"
swiftc -O -swift-version 5 \
    -module-cache-path "$PWD/.build/module-cache" \
    -o "$APP/Contents/MacOS/SmartRoute" \
    $SRCS \
    -framework SwiftUI -framework AppKit -framework Combine

echo "==> 编译 Wi-Fi 扫描组件"
# 免权限扫描附近 Wi-Fi 用（按指定 SSID 扫，不要定位权限）。少了它
# smartroute wifi scan 就退化成"查不到"，界面上的附近网络也是空的。
swiftc -O -module-cache-path "$PWD/.build/module-cache" \
    tools/wifiscan.swift -o "$APP/Contents/MacOS/wifiscan" || {
    echo "!! wifiscan 编译失败，附近网络扫描将不可用"; exit 1; }

echo "==> 拷贝资源（脚本 + 安装卸载器 + plist）"
cp smartroute.sh install.sh uninstall.sh com.user.smartroute.plist "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/smartroute.sh" \
         "$APP/Contents/Resources/install.sh" \
         "$APP/Contents/Resources/uninstall.sh"

echo "==> 写入 Info.plist"
# 注意：heredoc 不能加引号，否则 ${VERSION} 不会被展开（会字面量写进 plist）
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>SmartRoute</string>
    <key>CFBundleExecutable</key>
    <string>SmartRoute</string>
    <key>CFBundleIdentifier</key>
    <string>com.user.smartroute</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SmartRoute</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> 临时签名（ad-hoc）"
codesign --force --sign - "$APP" 2>/dev/null || true

echo
echo "构建完成: $PWD/$APP"
echo "运行: open \"$PWD/$APP\""
echo "建议移动到 /Applications 或 ~/Applications"

# ⚠️ 本脚本是"快速本地构建"：只编译当前主机的架构（Apple Silicon 上就是 arm64）。
# 要分发给别人（或装进 /Applications 长期用），必须用 build_release.sh，
# 它才会同时编 arm64 + x86_64 并 lipo 成通用二进制。
echo
echo "⚠️  注意：本次构建只含本机架构（$(lipo -info "$APP/Contents/MacOS/SmartRoute" 2>/dev/null | sed 's/.*: //')）。"
echo "    分发或安装到 /Applications 请改用: bash build_release.sh"

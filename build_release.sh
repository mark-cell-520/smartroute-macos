#!/bin/bash
# build_release.sh —— 构建可分发版本（通用二进制 + DMG + ZIP）
# 目标：macOS 13.0+，Apple Silicon + Intel 通吃；ad-hoc 签名（无需开发者账号）
set -e
cd "$(dirname "$0")"
APP="SmartRoute.app"
DIST="dist"
MC="$PWD/.build/module-cache"
MIN_OS="13.0"
VERSION="2.2"          # 改版本号只改这一行（Info.plist / ZIP / DMG 都跟着变）

echo "==> 清理"
# 只清自己生产的 ZIP 和暂存目录；*.dmg 是 build_dmg.sh 的产物，要留着，
# 否则跑一次 build_release.sh 就把用户辛苦打好的 DMG 删了
rm -rf "$APP" "$DIST/SmartRoute" "$DIST/SmartRoute-$VERSION" "$DIST"/SmartRoute-*-macOS.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST" "$MC"

# ---------- 1. 生成图标 ----------
echo "==> 生成应用图标"
swiftc -O -o "$PWD/.build/make_icon" SmartRouteApp/make_icon.swift -module-cache-path "$MC" 2>/dev/null
for sz in 16 32 48 128 256 512 1024; do
    "$PWD/.build/make_icon" "$PWD/.build/icon_$sz.png" "$sz" >/dev/null
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

# ---------- 2. 编译两个架构 ----------
# 源码用 glob，和 build_app.sh 用同一套规则。
# 曾经这里是手写清单，和 build_app.sh 各一份，两次新增 .swift 都只改了一处，
# 另一处漏掉直接编译报 "cannot find 'X' in scope"。glob 从根上消除这个问题。
# make_icon.swift 排除掉——它是生成图标的独立命令行工具，自带 main，不能编进 App。
SRCS="$(ls SmartRouteApp/*.swift | grep -v 'make_icon.swift' | tr '\n' ' ')"

echo "==> 编译 Apple Silicon 切片 (arm64, macOS $MIN_OS+)"
swiftc -O -swift-version 5 -module-cache-path "$MC" \
    -target "arm64-apple-macosx$MIN_OS" -o "$PWD/.build/arm64" $SRCS \
    -framework SwiftUI -framework AppKit -framework Combine

echo "==> 编译 Intel 切片 (x86_64, macOS $MIN_OS+)"
swiftc -O -swift-version 5 -module-cache-path "$MC" \
    -target "x86_64-apple-macosx$MIN_OS" -o "$PWD/.build/x86_64" $SRCS \
    -framework SwiftUI -framework AppKit -framework Combine

echo "==> 合并为通用二进制"
lipo -create "$PWD/.build/arm64" "$PWD/.build/x86_64" -output "$APP/Contents/MacOS/SmartRoute"
lipo -info "$APP/Contents/MacOS/SmartRoute"

# ---------- 3. 资源 ----------
echo "==> 编译 Wi-Fi 扫描组件（免权限，按指定 SSID 扫）"
swiftc -O -module-cache-path "$MC" tools/wifiscan.swift \
    -o "$APP/Contents/MacOS/wifiscan" || {
    echo "!! wifiscan 编译失败，附近网络扫描将不可用"; exit 1; }

echo "==> 拷贝资源"
cp smartroute.sh install.sh uninstall.sh com.user.smartroute.plist "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/smartroute.sh" \
         "$APP/Contents/Resources/install.sh" \
         "$APP/Contents/Resources/uninstall.sh"

# ---------- 4. Info.plist ----------
echo "==> 写入 Info.plist"
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
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
</dict>
</plist>
PLIST

# ---------- 5. 签名 ----------
echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP" 2>&1 | head -3 || true
codesign --verify --verbose "$APP" 2>&1 | head -3

# ---------- 6. 打包 ----------
STAGE="$DIST/SmartRoute"          # DMG 用：App + Applications 快捷方式 + 说明
ZROOT="$DIST/SmartRoute-$VERSION"      # ZIP 用：统一放进版本文件夹，解压即得
mkdir -p "$STAGE" "$ZROOT"
cp -R "$APP" "$STAGE/"
cp -R "$APP" "$ZROOT/"
ln -s /Applications "$STAGE/Applications"
# 安装说明：优先用完整的 INSTALL.md（含 FAQ/卸载/排障），缺失才用简版
if [ -f INSTALL.md ]; then
    cp INSTALL.md "$STAGE/安装说明.txt"
else
    cat > "$STAGE/安装说明.txt" <<'TXT'
SmartRoute for macOS —— 安装说明
================================

1. 把 SmartRoute.app 拖到「应用程序」文件夹（或直接在本窗口双击运行）

2. 首次打开如提示"无法打开，因为无法验证开发者"：
   请【右键 → 打开】，再点一次「打开」。（ad-hoc 签名未做 Apple 公证，只需一次。）

3. 打开后在「守护进程」页安装守护进程，之后每 20 秒自动检测并选路。

4. 想两个接口同时上网？在「双网并发」页开启（自动验证，失败自动还原）。
TXT
fi
chmod 644 "$STAGE/安装说明.txt"

cp "$STAGE/安装说明.txt" "$ZROOT/"

echo "==> 生成 ZIP（ditto：UTF-8 文件名 + 保留权限）"
ditto -c -k --sequesterRsrc --keepParent "$ZROOT" "$DIST/SmartRoute-$VERSION-macOS.zip"
# 去掉 ditto 产生的 __MACOSX 元数据条目，让压缩包更干净
zip -q -d "$DIST/SmartRoute-$VERSION-macOS.zip" "__MACOSX/*" 2>/dev/null || true
ls -la "$DIST/SmartRoute-$VERSION-macOS.zip"
python3 - "$DIST/SmartRoute-$VERSION-macOS.zip" <<'PYEOF2'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
assert not any("__MACOSX" in n for n in names), "仍有 __MACOSX 条目"
assert any(n.endswith("SmartRoute.app/Contents/MacOS/SmartRoute") for n in names), "缺少可执行文件"
assert any(n.endswith(".txt") for n in names), "缺少安装说明"
print("    ZIP 校验通过：%d 个条目" % len(names))
PYEOF2

echo "==> 生成 DMG（需要磁盘镜像权限；被系统策略阻止时用 ZIP 代替）"
if hdiutil create -volname "SmartRoute" -srcfolder "$STAGE" -ov -format UDZO \
        "$DIST/SmartRoute-$VERSION-macOS.dmg" >/tmp/hdi.log 2>&1; then
    ls -la "$DIST/SmartRoute-$VERSION-macOS.dmg"
    echo "    DMG 创建成功"
else
    echo "    ℹ️  当前环境不允许创建 DMG（沙箱/权限限制）"
    echo "    → 请使用 ZIP 分发；在普通终端里运行本脚本即可生成 DMG"
fi

echo
echo "==> 构建完成，产物在 $DIST/:"
ls -la "$DIST/"

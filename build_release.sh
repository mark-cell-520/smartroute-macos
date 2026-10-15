#!/bin/bash
# build_release.sh —— 构建可分发版本（通用二进制 + DMG + ZIP）
# 目标：macOS 13.0+，Apple Silicon + Intel 通吃；ad-hoc 签名（无需开发者账号）
set -e
cd "$(dirname "$0")"
APP="SmartRoute.app"
DIST="dist"
MC="$PWD/.build/module-cache"
MIN_OS="13.0"

echo "==> 清理"
rm -rf "$APP" "$DIST"
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
SRCS="SmartRouteApp/Shell.swift SmartRouteApp/Privileged.swift SmartRouteApp/ScriptLocator.swift \
      SmartRouteApp/NetworkModel.swift SmartRouteApp/Views.swift SmartRouteApp/SmartRouteApp.swift"

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
    <string>2.1</string>
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
STAGE="$DIST/SmartRoute"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/安装说明.txt" <<'TXT'
SmartRoute for macOS —— 安装说明
================================

1. 把 SmartRoute.app 拖到「应用程序」文件夹（或直接在本窗口双击运行）

2. 首次打开：
   如果提示"无法打开，因为无法验证开发者"，
   请【右键 → 打开】，然后在弹出的对话框里再点「打开」。
   （本地构建、ad-hoc 签名，未做 Apple 公证；只需操作一次，之后正常打开。）

3. 打开后在「守护进程」页点击「安装 / 重装守护进程」，输入管理员密码。
   之后每 20 秒自动检测：以太网没有外网时自动切到 Wi-Fi，恢复后自动切回。

4. 想两个接口同时上网？在「双网并发」页开启（会自动验证，失败自动还原）。

5. 卸载：App 内「守护进程」页点卸载，然后把 App 拖进废纸篓即可。

命令行用法（可选）：
  sudo /usr/local/bin/smartroute status     # 查看状态
  sudo smartroute balance on                # 开启双网并发
  smartroute rule add 10.0.0.0/8 en0        # 内网段走有线

系统要求：macOS 13.0 或更高（Apple Silicon / Intel 均可）
源码与文档：见 GitHub 仓库
TXT

echo "==> 生成 ZIP"
( cd "$STAGE" && zip -qry "../SmartRoute-2.1-macOS.zip" "SmartRoute.app" "安装说明.txt" )
ls -la "$DIST/SmartRoute-2.1-macOS.zip"

echo "==> 生成 DMG（需要磁盘镜像权限；被系统策略阻止时用 ZIP 代替）"
if hdiutil create -volname "SmartRoute" -srcfolder "$STAGE" -ov -format UDZO \
        "$DIST/SmartRoute-2.1-macOS.dmg" >/tmp/hdi.log 2>&1; then
    ls -la "$DIST/SmartRoute-2.1-macOS.dmg"
    echo "    DMG 创建成功"
else
    echo "    ℹ️  当前环境不允许创建 DMG（沙箱/权限限制）"
    echo "    → 请使用 ZIP 分发；在普通终端里运行本脚本即可生成 DMG"
fi

echo
echo "==> 构建完成，产物在 $DIST/:"
ls -la "$DIST/"

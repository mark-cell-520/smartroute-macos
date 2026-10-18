#!/bin/bash
# build_release.sh —— 构建可分发版本（通用二进制 + DMG + ZIP）
# 目标：macOS 13.0+，Apple Silicon + Intel 通吃；ad-hoc 签名（无需开发者账号）
set -e
cd "$(dirname "$0")"
APP="SmartRoute.app"
DIST="dist"
MC="$PWD/.build/module-cache"
MIN_OS="13.0"
# 版本号唯一来源：仓库根目录的 VERSION 文件。以前这里、build_dmg.sh、
# sync-github.sh、make_dmg_bg.swift 各写一份，改漏一个就出现
# "ZIP 是 2.2、DMG 背景图还是 2.1、文档说 2.1"这种漂移。
VERSION="$(cat VERSION 2>/dev/null | tr -d '[:space:]')"
[ -n "$VERSION" ] || { echo "!! 读不到 VERSION 文件"; exit 1; }

echo "==> 清理"
# 只清自己生产的 ZIP 和暂存目录；*.dmg 是 build_dmg.sh 的产物，要留着，
# 否则跑一次 build_release.sh 就把用户辛苦打好的 DMG 删了
rm -rf "$APP" "$DIST/SmartRoute" "$DIST/SmartRoute-$VERSION" "$DIST"/SmartRoute-*-macOS.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST" "$MC"

# ---------- 1. 生成图标 ----------
echo "==> 生成应用图标"
# 图标编译失败不能一票否决整个发布（set -e 下会）：App 没有图标照样能跑，
# 顶多 Dock 里是默认图标。以前这里失败会让 build_release.sh 整体退出，
# 用户以为发布失败了，其实只差一张图。
if swiftc -O -o "$PWD/.build/make_icon" SmartRouteApp/make_icon.swift -module-cache-path "$MC" 2>/dev/null; then
    for sz in 16 32 48 128 256 512 1024; do
        "$PWD/.build/make_icon" "$PWD/.build/icon_$sz.png" "$sz" >/dev/null
    done
    HAVE_ICON=1
else
    echo "    ⚠️  图标工具编译失败，将使用默认图标（不影响功能）"
    HAVE_ICON=0
fi
# 组装 icns 必须放在 HAVE_ICON 判断**里面**。
#
# 放在外面的后果：图标工具编译失败时 HAVE_ICON=0，但这里的 python 仍然照跑，
# 而 icon_*.png 一个都没生成 → open() 抛 FileNotFoundError → set -e 下整个
# 脚本中止。此时第 19 行已经 rm -rf 掉旧 App 和旧 ZIP 了——用户丢掉的不仅是
# 一次发布，还有上一版能用的产物，而屏幕上只有一段 Python traceback。
#
# 这正是上面那条注释想避免的情况（"图标编译失败不能一票否决整个发布"），
# 但只挡住了 swiftc 那一步，没挡住组装这一步。
if [ "${HAVE_ICON:-0}" = "1" ]; then
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
fi
# 图标没生成成功就别复制（复制半个文件会让 App 起不来）
if [ "${HAVE_ICON:-0}" = "1" ] && [ -s "$PWD/.build/AppIcon.icns" ]; then
    cp "$PWD/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "    (i) 跳过图标（用系统默认）"
fi

# ---------- 2. 编译两个架构 ----------
# 源码用 glob，和 build_app.sh 用同一套规则。
# 曾经这里是手写清单，和 build_app.sh 各一份，两次新增 .swift 都只改了一处，
# 另一处漏掉直接编译报 "cannot find 'X' in scope"。glob 从根上消除这个问题。
# make_icon.swift 排除掉——它是生成图标的独立命令行工具，自带 main，不能编进 App。
# 排除要按完整文件名匹配：grep -v 'make_icon.swift' 是子串匹配，
# 以后加个 my_make_icon.swift 之类的会被误排除，而且很难查。
SRCS="$(ls SmartRouteApp/*.swift | grep -v '/make_icon\.swift$' | tr '\n' ' ')"

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
echo "==> 编译 Wi-Fi 扫描组件（免权限，按指定 SSID 扫，也要通用二进制）"
# 必须编两架构再 lipo。以前只编主机架构：Apple Silicon 机器上产出的 helper 是
# Non-fat arm64，Intel 用户一 exec 就是 "Bad CPU type"，
# 而 wifi_scan_bin() 只查 -x 不查架构——于是 wifi scan 静默降级成
# "附近没有已保存的网络在范围"，tryall/auto 的排序也跟着退化，
# 用户完全看不出是架构问题。
swiftc -O -module-cache-path "$MC" -target "arm64-apple-macosx$MIN_OS" \
    tools/wifiscan.swift -o "$PWD/.build/wifiscan_arm64" || {
    echo "!! wifiscan (arm64) 编译失败，附近网络扫描将不可用"; exit 1; }
swiftc -O -module-cache-path "$MC" -target "x86_64-apple-macosx$MIN_OS" \
    tools/wifiscan.swift -o "$PWD/.build/wifiscan_x86_64" || {
    echo "!! wifiscan (x86_64) 编译失败，附近网络扫描将不可用"; exit 1; }
lipo -create "$PWD/.build/wifiscan_arm64" "$PWD/.build/wifiscan_x86_64" \
    -output "$APP/Contents/MacOS/wifiscan"
lipo -info "$APP/Contents/MacOS/wifiscan"

# 架构断言：主程序和 helper 都必须是通用二进制。少了这道断言，
# 以后有人改回单架构编译，产物会静默退化（上面说的那种）。
for bin in SmartRoute wifiscan; do
    f="$APP/Contents/MacOS/$bin"
    if ! lipo -info "$f" 2>/dev/null | grep -q "x86_64" || \
       ! lipo -info "$f" 2>/dev/null | grep -q "arm64"; then
        echo "!! $bin 不是通用二进制（缺 x86_64 或 arm64），拒绝打包"
        lipo -info "$f" || true
        exit 1
    fi
    echo "    $bin: $(lipo -info "$f" | sed 's/.*are: //')"
done

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
# 校验的退出码必须能传出来。`cmd 2>&1 | head -3` 的退出码是 head 的
# （恒 0），于是签名失败、校验失败都静默通过，坏签名直接进 ZIP/DMG，
# 用户侧表现为"已损坏"，而文档让人以为只是 Gatekeeper 的事。
# 这里先存退出码再输出，head 只负责截断显示。
codesign --force --deep --sign - "$APP" > "$PWD/.build/sign.log" 2>&1
_sign_rc=$?
head -3 "$PWD/sign.log" 2>/dev/null || head -3 "$PWD/.build/sign.log"
[ "${_sign_rc}" -eq 0 ] || { echo "!! 签名失败（退出码 ${_sign_rc}）"; exit 1; }

codesign --verify --verbose "$APP" > "$PWD/.build/verify.log" 2>&1
_verify_rc=$?
head -3 "$PWD/.build/verify.log"
[ "$_verify_rc" -eq 0 ] || {
    echo "!! 签名校验失败（退出码 ${_verify_rc}），拒绝打包"
    cat "$PWD/.build/verify.log"
    exit 1
}

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
# 内嵌主脚本必须在，且带可执行位。
# 为什么单查它：ScriptLocator.scriptPath 在 bundled 脚本没有 +x 时**静默**
# return installedScript（/usr/local/bin/smartroute），而 daemonScriptOutdated
# 又要求 bundled 可执行才做版本对比——于是"内置脚本不可用"恰好让现有的版本
# 不一致告警失效。用户机器上 App 会一声不响地跑去用系统里那份旧脚本，
# 而 StatusView 只显示路径、不告警（且不在默认落地页）。
# install.sh / uninstall.sh 不查执行位：App 从不用 exec 它们，而是
# `bash <path>`，它们的 +x 与功能无关，缺失也不静默（bash 退出非零会被
# installDaemon 的 failed 标志接到）。
for n in names:
    if n.endswith("Contents/Resources/smartroute.sh"):
        assert (z.getinfo(n).external_attr >> 16) & 0o111, "内嵌 smartroute.sh 没有可执行位"
        break
else:
    assert False, "ZIP 里缺少 Contents/Resources/smartroute.sh"
# 版本号不查：VERSION 是唯一来源（见本脚本第 13 行），同一个 $VERSION 同时喂
# Info.plist、ZIP 根目录名和 ZIP 文件名，除非有人手改 heredoc，否则不可能漂移。
print("    ZIP 校验通过：%d 个条目" % len(names))
PYEOF2

# DMG 交给 build_dmg.sh 做（它带背景图、Applications 快捷方式、布局图标位置）。
# 以前这里也生成一个 -ov 的 DMG，结果把 build_dmg.sh 的成果覆盖成没有背景/布局的
# 朴素镜像——两个脚本争同一个路径，谁后跑谁赢，用户拿到哪个全看运气。
if [ -f "$DIST/SmartRoute-$VERSION-macOS.dmg" ]; then
    echo "==> 已有 DMG（build_dmg.sh 的产物），不覆盖"
    ls -la "$DIST/SmartRoute-$VERSION-macOS.dmg"
    echo "    要重新打 DMG：bash build_dmg.sh"
else
    echo "==> 未生成 DMG（本脚本只出 ZIP）"
    echo "    需要 DMG：bash build_dmg.sh（需在普通终端运行）"
fi

echo
echo "==> 构建完成，产物在 $DIST/:"
ls -la "$DIST/"

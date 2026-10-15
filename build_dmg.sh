#!/bin/bash
# 一键构建可下载安装的 DMG（给最终用户用）
#
#   bash build_app.sh && bash build_dmg.sh
#
# ⚠️ 必须在普通终端运行：创建磁盘映像需要设备访问权限，
#    受限环境（沙箱/CI）会报 newfs_hfs: Operation not permitted。
set -euo pipefail
cd "$(dirname "$0")"

VERSION="2.1"
VOL="SmartRoute ${VERSION}"
APP="SmartRoute.app"
DMG="dist/SmartRoute-${VERSION}-macOS.dmg"
STAGE=".dmgstage"
BG=".dmgbg.png"                     # 生成在暂存目录外，避免被 rm -rf 清掉
ICON=".build/AppIcon.icns"          # 卷图标（build_app.sh / build_release.sh 生成）
MNT=""

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; [ -d "$MNT" ] && hdiutil detach "$MNT" >/dev/null 2>&1; exit 1; }

cleanup() {
    if [ -n "$MNT" ] && [ -d "$MNT" ]; then hdiutil detach "$MNT" >/dev/null 2>&1; fi
    rm -rf "$STAGE" "$BG"
    [ -n "$MNT" ] && rm -rf "$MNT"
    rm -f "dist/.SmartRoute-${VERSION}-rw".*.dmg
    return 0
}
trap cleanup EXIT

# ---------- 0. 前置检查 ----------
[ -d "$APP" ] || die "找不到 ${APP}，请先运行: bash build_app.sh"
command -v hdiutil >/dev/null || die "系统缺少 hdiutil"
say "准备打包 ${APP}（版本 ${VERSION}）"

# ---------- 1. 生成背景图 ----------
say "生成 DMG 背景图"
mkdir -p tools
if [ ! -x tools/make_dmg_bg ]; then
    swiftc -O tools/make_dmg_bg.swift -o tools/make_dmg_bg 2>/dev/null \
        || die "背景图编译失败（需要 Xcode 命令行工具: xcode-select --install）"
fi
tools/make_dmg_bg "$BG" >/dev/null

# ---------- 2. 装配暂存目录 ----------
say "装配安装目录（App + Applications 快捷方式 + 安装说明）"
rm -rf "$STAGE"; mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$BG" "$STAGE/.background/dmg_bg.png"   # Finder 背景图（相对卷根引用）
# 卷图标：Finder 里这个磁盘映像显示成 App 的图标，而不是 generic disk
if [ ! -f "$ICON" ] && [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
    ICON="$APP/Contents/Resources/AppIcon.icns"   # 兜底：从已构建的 App 里取
fi
if [ -f "$ICON" ]; then cp "$ICON" "$STAGE/.VolumeIcon.icns"; fi
if [ -f INSTALL.md ]; then cp INSTALL.md "$STAGE/安装说明.txt"; chmod 644 "$STAGE/安装说明.txt"; fi

# ---------- 3. 先建"可写"映像 ----------
# 关键：UDZO 是只读压缩格式，Finder 没法往只读卷写 .DS_Store，
# 布局设置只会留在内存里、不会固化进 DMG（用户打开还是朴素窗口）。
# 所以标准做法是两步：先建 UDRW 可写映像 → 挂载设置布局 → 再 convert 成 UDZO。
say "创建可写映像（UDRW，约 10-30 秒）"
RW="dist/.SmartRoute-${VERSION}-rw.$$.dmg"
rm -f "$RW"
CREATE_LOG="$(mktemp)"
if ! hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov -o "$RW" >"$CREATE_LOG" 2>&1; then
    echo "--- hdiutil 输出 ---" >&2; tail -5 "$CREATE_LOG" >&2; rm -f "$CREATE_LOG" "$RW"
    die "映像创建失败（旧文件未动）。若提示 Operation not permitted，说明当前环境无权创建设备映像，请改用普通终端运行本脚本"
fi
rm -f "$CREATE_LOG"
[ -s "$RW" ] || { rm -f "$RW"; die "映像创建后为空文件（旧文件未动）"; }

# ---------- 4. 挂载（可写）并设置 Finder 布局 ----------
say "挂载并设置窗口布局"
# 必须挂到默认位置 /Volumes/<卷名>：Finder 只把 /Volumes 下的卷识别为 disk，
# 挂到 /tmp 的话 "tell disk ..." 会找不到对象，布局必然失败。
# 这里不能加 -readonly，否则 Finder 写不了 .DS_Store。
ATTACH_OUT="$(hdiutil attach -noverify -noautoopen "$RW" 2>&1)" || {
    echo "$ATTACH_OUT" >&2
    die "映像挂载失败，产物可能损坏"
}
MNT="$(printf '%s\n' "$ATTACH_OUT" | awk -F'\t' '/GUID_partition_scheme|Apple_HFS/{print $NF; exit}')"
[ -n "$MNT" ] && [ -d "$MNT" ] || MNT="/Volumes/$VOL"
[ -d "$MNT" ] || die "找不到挂载点: $MNT"
say "  挂载到 $MNT"

# macOS 没有 timeout 命令：osascript 在没有"自动化"权限的环境里会一直挂着不返回，
# 用后台进程 + sleep + kill 自己实现一个超时，避免整个脚本卡死
run_as_with_timeout() {           # run_as_with_timeout <秒> <applescript 文件>
    local secs="$1" script="$2" tmpout; tmpout="$(mktemp)"
    osascript "$script" >"$tmpout" 2>&1 &
    local pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) &
    local killer=$!
    wait "$pid" 2>/dev/null
    kill "$killer" 2>/dev/null
    cat "$tmpout"; rm -f "$tmpout"
}

# AppleScript 每一步单独 try：某一项失败不影响其他项；最后把真实错误打出来方便排查
AS_FILE="$(mktemp /tmp/smartroute-layout.XXXXXX)"
cat > "$AS_FILE" <<AS
tell application "Finder"
    tell disk "$VOL"
        try
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 120, 1160, 700}
        end try
        try
            set vo to the icon view options of container window
            set arrangement of vo to not arranged
            set icon size of vo to 96
            set background picture of vo to file ".background:dmg_bg.png"
        end try
        try
            set position of item "SmartRoute.app" of container window to {300, 240}
            set position of item "Applications" of container window to {760, 240}
            set position of item "安装说明.txt" of container window to {530, 420}
            try
                -- 让卷用 .VolumeIcon.icns 而不是 generic disk 图标
                do shell script "/usr/bin/SetFile -a C '$MNT' 2>/dev/null || true"
            end try
        end try
        try
            close
            open
            delay 2
        end try
    end tell
end tell
AS
AS_OUT="$(run_as_with_timeout 25 "$AS_FILE")"
rm -f "$AS_FILE"
if printf '%s' "$AS_OUT" | grep -qi "not authorized\|not permitted\|not allowed\|assistive\|access control"; then
    say "  ⚠️ 没有 Finder 自动化权限（不影响安装，只是窗口朴素些）"
    say "     想要漂亮窗口：系统设置 → 隐私与安全性 → 自动化 → 允许你的终端控制 Finder，再跑一次"
elif [ -n "$AS_OUT" ]; then
    say "  ⚠️ 布局设置未完全成功（不影响安装）:"
    printf '     %s\n' "$AS_OUT" | head -4
else
    say "  ✓ 图标位置与背景已设置"
fi

# ---------- 5. 校验内容（含 .DS_Store）后卸载 ----------
say "校验映像内容"
ok=1
[ -d "$MNT/$APP" ]        || { echo "  ✗ 缺少 $APP"; ok=0; }
[ -L "$MNT/Applications" ] || { echo "  ✗ 缺少 Applications 快捷方式"; ok=0; }
[ -f "$MNT/.VolumeIcon.icns" ] && say "  ✓ 卷图标已内置（Finder 显示 App 图标）" || echo "  ⚠️ 无卷图标（不影响使用）"
[ -f "$MNT/安装说明.txt" ]  || echo "  ⚠️ 缺少安装说明（不影响使用）"
if [ -f "$MNT/.DS_Store" ]; then
    say "  ✓ .DS_Store 已写入（窗口布局会保留）"
else
    say "  ⚠️ 没生成 .DS_Store，布局不会固化（打开 DMG 是朴素窗口，不影响安装）"
fi
[ "$ok" = "1" ] || die "映像内容不完整"
# 卸载前先关掉这个卷的窗口，让 Finder 把 .DS_Store 落盘
# （只关本卷窗口，不动用户其他 Finder 窗口）
osascript -e "tell application \"Finder\" to close (every window of disk \"$VOL\")" >/dev/null 2>&1
sleep 1
hdiutil detach "$MNT" >/dev/null 2>&1
MNT=""

# ---------- 6. 转换成压缩 DMG ----------
say "转换成压缩 DMG（UDZO）"
CONVERT_LOG="$(mktemp)"
if ! hdiutil convert "$RW" -format UDZO -ov -o "$DMG" >"$CONVERT_LOG" 2>&1; then
    echo "--- hdiutil 输出 ---" >&2; tail -5 "$CONVERT_LOG" >&2; rm -f "$CONVERT_LOG"
    die "转换成 DMG 失败（可写映像仍在: $RW，可手动转换）"
fi
rm -f "$CONVERT_LOG" "$RW"
[ -s "$DMG" ] || die "转换后的 DMG 为空文件"

# ---------- 7. 结果 ----------
SIZE="$(du -h "$DMG" | awk '{print $1}')"
say "✅ 完成: $DMG ($SIZE)"
echo
echo "上传 GitHub Release:"
echo "  gh release create v${VERSION} dist/SmartRoute-${VERSION}-macOS.zip dist/SmartRoute-${VERSION}-macOS.dmg"
echo
echo "⚠️  本 App 为 ad-hoc 签名（无 Apple 开发者账号），用户首次打开可能被 Gatekeeper 拦截，"
echo "    解决方法（右键 → 打开）已写在随附《安装说明.txt》里。"

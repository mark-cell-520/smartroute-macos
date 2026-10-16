#!/bin/bash
# smartroute 安装脚本：安装到 /usr/local/bin 并注册 launchd 守护进程（root）
set -e
cd "$(dirname "$0")"

echo "==> 安装 smartroute 到 /usr/local/bin"
sudo install -m 0755 smartroute.sh /usr/local/bin/smartroute

# Wi-Fi 扫描组件（免权限，按指定 SSID 扫）。装到 /usr/local/bin 下，
# 这样 /usr/local/bin/smartroute 同目录就能找到它——守护进程和命令行都用得到。
# 少了它只是退化：wifi scan 查不到附近网络，候选排序退回按保存顺序。
#
# 为什么要多位置找：这个脚本有两种跑法——从源码目录跑（helper 就在旁边），
# 和从 App bundle 里跑（App 内「安装守护进程」按钮触发，此时本脚本位于
# Contents/Resources/，而 helper 在 Contents/MacOS/，不在同一目录）。
# 以前只看 CWD，于是从 App 里安装时永远找不到 helper，
# 而提示是"重新构建即可"——指向完全错误的方向，用户怎么重建都没用。
_wifiscan=""
for _cand in \
    "$(dirname "$0")/wifiscan" \
    "$(dirname "$0")/../MacOS/wifiscan" \
    "$(dirname "$0")/tools/wifiscan" \
    "$(dirname "$0")/../tools/wifiscan"; do
    if [ -x "$_cand" ]; then _wifiscan="$_cand"; break; fi
done
if [ -n "$_wifiscan" ]; then
    sudo install -m 0755 "$_wifiscan" /usr/local/bin/smartroute-wifiscan
    echo "==> 已安装 Wi-Fi 扫描组件（来自 ${_wifiscan}）"
else
    echo "!! 没找到 wifiscan 可执行文件（附近网络扫描不可用）"
    echo "   已找过：本目录、../MacOS/、tools/、../tools/"
    echo "   若从 App 里点的安装：请先跑一次 bash build_app.sh 生成 helper"
    echo "   若从源码目录跑的：helper 由 build_app.sh / build_release.sh 产出"
fi

echo "==> 写入默认配置 /etc/smartroute.conf"
if [ ! -f /etc/smartroute.conf ]; then
    echo "# smartroute 配置文件" | sudo tee /etc/smartroute.conf >/dev/null
    echo "MODE=auto" | sudo tee -a /etc/smartroute.conf >/dev/null
fi

echo "==> 注册 launchd 守护进程（每 20 秒检测一次）"
sudo cp com.user.smartroute.plist /Library/LaunchDaemons/com.user.smartroute.plist
sudo chown root:wheel /Library/LaunchDaemons/com.user.smartroute.plist
sudo chmod 0644 /Library/LaunchDaemons/com.user.smartroute.plist

# macOS 13+ 用 bootstrap，旧版用 load
if ! sudo launchctl bootstrap system /Library/LaunchDaemons/com.user.smartroute.plist 2>/dev/null; then
    sudo launchctl load /Library/LaunchDaemons/com.user.smartroute.plist 2>/dev/null || true
fi

echo
echo "安装完成！常用命令："
echo "  sudo smartroute status     # 查看当前状态"
echo "  sudo smartroute test       # 手动探测两个接口"
echo "  sudo smartroute set wifi   # 强制走 Wi-Fi（auto/ethernet/wifi）"
echo "  tail -f /var/log/smartroute.log   # 查看日志"
echo
echo "卸载: sudo bash uninstall.sh"

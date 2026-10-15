#!/bin/bash
# smartroute 安装脚本：安装到 /usr/local/bin 并注册 launchd 守护进程（root）
set -e
cd "$(dirname "$0")"

echo "==> 安装 smartroute 到 /usr/local/bin"
sudo install -m 0755 smartroute.sh /usr/local/bin/smartroute

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

#!/bin/bash
# smartroute 卸载脚本
set -e
echo "==> 停止并移除 launchd 守护进程"
sudo launchctl bootout system/com.user.smartroute 2>/dev/null \
  || sudo launchctl unload /Library/LaunchDaemons/com.user.smartroute.plist 2>/dev/null \
  || true

sudo rm -f /Library/LaunchDaemons/com.user.smartroute.plist
sudo rm -f /usr/local/bin/smartroute
sudo rm -f /etc/smartroute.conf
sudo rm -rf /var/db/smartroute
echo "==> 已卸载（日志 /var/log/smartroute.log 保留，可手动删除）"

#!/bin/bash
# smartroute 安装脚本：安装到 /usr/local/bin 并注册 launchd 守护进程（root）
#
# 设计原则（从用户心理出发）：
#   1. **不允许静默失败**。用户装完会用几周，如果守护进程其实没起来，
#      他几个星期后才发现"这东西根本没动"——那时他已经不记得安装过程了，
#      无从排查。所以每一步都要验证，失败就说清楚卡在哪。
#   2. **装完要告诉用户会发生什么**。改网络设置是高风险操作，
#      用户第一反应是"它在动我的网络？"。明确说出来，并给出撤销方法，
#      不安感才会消。
#   3. **重复安装不是错误**，说清"已装过，配置保留"就行，别报错。
set -e
cd "$(dirname "$0")"

C_G=""; C_Y=""; C_R=""; C_0=""
if [ -t 1 ]; then
    C_G="$(printf '\033[32m')"; C_Y="$(printf '\033[33m')"
    C_R="$(printf '\033[31m')"; C_0="$(printf '\033[0m')"
fi
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$1"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$1"; }
die()  { printf '  %s✗%s %s\n' "$C_R" "$C_0" "$1" >&2; exit 1; }

PLIST_LABEL="com.user.smartroute"
DAEMON_PLIST="/Library/LaunchDaemons/$PLIST_LABEL.plist"

# ---------- 0. 是否已安装 ----------
# 重复安装本身没错（升级就走这条路），但要说清"配置会保留"，
# 否则用户会以为自己的设置被重置了。
ALREADY=0
[ -x /usr/local/bin/smartroute ] && ALREADY=1
if [ "$ALREADY" = "1" ]; then
    echo "==> 检测到已安装，这次是升级/重装"
    echo "    /etc/smartroute.conf 与 /Users/Shared/smartroute.conf 都会保留，不会重置"
fi

# ---------- 1. 主程序 ----------
echo "==> 安装 smartroute 到 /usr/local/bin"
sudo install -m 0755 smartroute.sh /usr/local/bin/smartroute
# install 在 set -e 下失败就会退出，但退出信息是裸的 bash 报错。
# 补一句人话：最常见的原因是 /usr/local/bin 不存在或权限不对。
[ -x /usr/local/bin/smartroute ] || die "安装失败：/usr/local/bin/smartroute 不存在或不可执行。
    常见原因：/usr/local/bin 目录不存在（新建即可：sudo mkdir -p /usr/local/bin）"
ok "已安装 /usr/local/bin/smartroute"

# ---------- 2. Wi-Fi 扫描组件 ----------
# 免权限，按指定 SSID 扫。装到 /usr/local/bin 下，
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
    ok "已安装 Wi-Fi 扫描组件（来自 ${_wifiscan}）"
else
    warn "没找到 wifiscan 可执行文件"
    echo "    已找过：本目录、../MacOS/、tools/、../tools/"
    echo "    影响：wifi scan 查不到附近网络，故障转移的候选排序退回按保存顺序"
    echo "    修复：若从 App 里点的安装，先跑一次 bash build_release.sh 生成 helper"
    echo "          若从源码目录跑的，helper 由 build_release.sh 产出"
    echo "    （不影响自动选路主功能，可继续）"
fi

# ---------- 3. 配置 ----------
# 只在不存在时创建默认值。已存在就一个字都不改——
# 用户可能刚在 App 里调过 MODE/BALANCE，覆盖掉等于偷偷改他的设置。
echo "==> 写入默认配置 /etc/smartroute.conf"
if [ -f /etc/smartroute.conf ]; then
    ok "已存在，保留不动（MODE=$(grep -m1 '^MODE=' /etc/smartroute.conf | cut -d= -f2 || echo 未设置)）"
else
    printf '# smartroute 配置文件\nMODE=auto\n' | sudo tee /etc/smartroute.conf >/dev/null
    ok "已创建，默认 MODE=auto"
fi

# 用户级配置也要在安装时建出来，而且权限必须是 644。
#
# 不安这一行的后果是提权：守护进程以 root 每 20 秒解析
# /Users/Shared/smartroute.conf，而 /Users/Shared 是 1777。
# 文件不存在时，**任何本地用户都能建一个**，让 root 按他的配置选路、
# 测速、开关并发。这不是理论问题——目录权限就在那里。
#
# 建出来之后还有第二层：脚本的 conf_parse_file 会拒绝群/他人可写的配置
# （见 smartroute.sh），所以即使有人事后 chmod 666 也不会生效。
# 两层都要有：install 负责"不让它被预创建"，解析器负责"不让它被改宽"。
if [ -f /Users/Shared/smartroute.conf ]; then
    ok "用户级配置已存在，保留不动"
else
    printf '# smartroute 用户级配置（优先级高于 /etc/smartroute.conf）\n' \
        | sudo tee /Users/Shared/smartroute.conf >/dev/null
    # 644：属主可写、其他人只读。1777 目录里新建文件默认可能是 644，
    # 但显式 chmod 不依赖 umask，也不会被用户的 shell 配置改掉。
    sudo chmod 644 /Users/Shared/smartroute.conf
    # ⚠️ 必须 chown 给控制台用户，不能留着 root 属主。
    #
    # 用户级配置的设计前提是"App/普通用户可写"（它就是为此存在的：
    # 优先级高于 /etc，且改它不需要 sudo）。而 `sudo tee` 建出来的文件
    # 属主是 root，/Users/Shared 又带 sticky 位 → conf_set 两条路都堵：
    #   · 路径一同目录 tmp + mv：sticky 目录里 rename 不掉他人（root）的文件
    #   · 路径二 cat >：打不开 644 的 root 文件
    # 实测验证过 sticky 语义（/private/tmp 1777，mv 一个自己的文件去覆盖
    # root 拥有的文件 → Permission denied；对照 mv 自己拥有的文件 OK）。
    #
    # 后果链：conf_set 返回 1 → cmd_set die「该文件属于 root…请 sudo chown」；
    # cmd_wifi auto on / cmd_boost 的 conf_set_kv 同样失败（这两个调用方
    # 都有明确报错，不是静默）。cmd_fixconf 和 conf_set:1782-1788 的存在
    # 都说明这个状态是**已知坏状态**——而 install.sh 自己又在制造它。
    # 全新安装后普通用户 set / App 保存必失败。
    #
    # 本机 /Users/Shared/smartroute.conf 现在是 mm 属主，说明确实有人已经
    # 手工修过一次。
    _console_uid="$(stat -f '%u' /dev/console 2>/dev/null || echo 0)"
    _console_user="$(stat -f '%Su' /dev/console 2>/dev/null || echo root)"
    if [ "$_console_uid" != "0" ]; then
        sudo chown "$_console_uid" /Users/Shared/smartroute.conf 2>/dev/null
    fi
    ok "已创建用户级配置 /Users/Shared/smartroute.conf（644，属主 ${_console_user}）"
fi

# ---------- 4. 守护进程 ----------
# 这是整个安装里**唯一不能失败**的一步：守护进程不跑，
# 自动选路、故障转移、双网并发全都不会发生，而用户完全看不出来。
# 以前这里 bootstrap 失败就 `|| true` 静默跳过，用户以为装好了，
# 实际什么都没发生——几周后才发现，那时已无从排查。
echo "==> 注册 launchd 守护进程（每 20 秒检测一次）"
sudo cp com.user.smartroute.plist "$DAEMON_PLIST"
sudo chown root:wheel "$DAEMON_PLIST"
sudo chmod 0644 "$DAEMON_PLIST"

if sudo launchctl bootstrap system "$DAEMON_PLIST" 2>/dev/null; then
    ok "已通过 bootstrap 注册"
else
    # bootstrap 失败的常见原因是"已经加载过了"（重复安装），
    # 这种情况先 kickstart 重启一下，让新代码生效。
    if sudo launchctl kickstart -k "system/$PLIST_LABEL" 2>/dev/null; then
        ok "已加载过，已用新代码重启守护进程"
    elif sudo launchctl load "$DAEMON_PLIST" 2>/dev/null; then
        ok "已通过 load 注册（旧版 macOS）"
    fi
fi

# 不管走哪条路，最后都必须确认它真的在跑。
# launchctl print 能查到 = job 已加载。查不到就是没起来，必须告诉用户。
if sudo launchctl print "system/$PLIST_LABEL" >/dev/null 2>&1; then
    ok "守护进程已加载并运行（system/${PLIST_LABEL}）"
else
    echo
    printf '  %s✗%s 守护进程没起来——自动选路不会工作。\n' "$C_R" "$C_0"
    echo "    已完成的：程序文件、配置文件都已装好。"
    echo "    没完成的：launchd 没接受这个 job。"
    echo "    请手动排查："
    echo "      sudo launchctl bootstrap system $DAEMON_PLIST"
    echo "      sudo launchctl print system/$PLIST_LABEL"
    echo "    或看系统日志：log show --predicate 'subsystem==\"com.apple.launchd\"' --last 5m"
    exit 1
fi

# ---------- 5. 装完之后：说清会发生什么 ----------
# 用户此刻最不安的问题是"它在动我的网络吗/我能撤销吗"。
# 主动回答，比让他自己猜或去翻文档好得多。
echo
echo "安装完成。接下来会发生什么："
echo "  · 每 20 秒检查一次两个接口哪个能上网，自动把默认路由切到能用的那个"
echo "  · 只在检测到变化时才切换，不会来回横跳（有冷却期）"
echo "  · 想收到切换通知：sudo smartroute set NOTIFY=1（默认不弹，免打扰）"
echo "  · 不动你的 VPN、不动 DNS、不装任何驱动"
echo
# 注意：这里给的命令必须真实存在。smartroute 没有 watch stop/start 子命令
# （入口只有 watch|once|run），照不存在的命令敲只会得到一段 usage，反而更困惑。
# 暂停就是让 launchd 别跑它，用 launchctl 才是对的。
echo "想暂停或撤销："
echo "  · 临时停用（重启后会自动恢复）："
echo "      sudo launchctl bootout system/com.user.smartroute"
echo "  · 彻底停用（重启也不恢复）："
echo "      sudo launchctl disable system/com.user.smartroute"
echo "  · 重新启用："
echo "      sudo launchctl enable system/com.user.smartroute"
echo "      sudo launchctl bootstrap system /Library/LaunchDaemons/com.user.smartroute.plist"
# 卸载命令要给绝对路径。原来写的是相对路径 "sudo bash uninstall.sh"，
# 用户照抄时只要换了个目录就是 "No such file or directory"——
# 而卸载是他最想顺利完成的动作，卡在这一步特别恼火。
echo "  · 彻底卸载：  sudo bash \"$(dirname "$0")/uninstall.sh\""
echo "    （卸载会还原网络服务顺序；DNS/VPN/代理都没动过）"
echo
# ── App 版本提醒 ──────────────────────────────────────────────
# install.sh 从来不碰 /Applications/SmartRoute.app（App 是拖进去的，
# 见 INSTALL.md）。于是用户跑完 install.sh、看到下面打印"安装完成"，
# 会以为一切都更新了——而 App 还是几天前的旧版，界面上继续显示旧结论。
# 这是"假的完成感"：比明说没装更糟，因为它让人不再去查。
#
# 这里能做的有限（不能写 /Applications，也不该悄悄覆盖用户的应用），
# 但至少要把状态说清楚，并给出确切的更新命令。
APP="/Applications/SmartRoute.app"
# install.sh 第 13 行已经 cd 到脚本所在目录，所以相对路径可用；
# 回显时用 pwd 拼成绝对路径，用户照抄命令时不管当前在哪个目录都对。
# 候选按**版本号**挑最新的，不按写死顺序。
# 曾经写死顺序取 dist/SmartRoute-2.2/SmartRoute.app（一个 10 月 19 日的
# 2.2 构建），于是每次重装都提示"App 是旧版"并给出把用户降级回 2.2 的
# 复制命令——而仓库根的 SmartRoute.app 才是当前源码构建的 2.5。
# 2026-10-24 实测踩到：提示里的路径是 dist/SmartRoute-2.2，照抄即降级。
NEWAPP=""; NEWVER=""
_cands=""
for c in "dist/SmartRoute-2.2/SmartRoute.app" "dist/SmartRoute/SmartRoute.app" "SmartRoute.app"; do
    [ -d "$c" ] || continue
    _v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$c/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
    _cands="$_cands${_v}"$'\t'"$(pwd)/${c}"$'\n'
done
if [ -n "$_cands" ]; then
    NEWVER="$(printf '%s' "$_cands" | sort -V | tail -1 | cut -f1)"
    NEWAPP="$(printf '%s' "$_cands" | sort -V | tail -1 | cut -f2)"
fi
if [ -d "$APP" ]; then
    APP_BIN="$APP/Contents/MacOS/SmartRoute"
    APPVER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo)"
    if [ -n "$NEWAPP" ] && [ -f "$NEWAPP/Contents/MacOS/SmartRoute" ]; then
        if cmp -s "$APP_BIN" "$NEWAPP/Contents/MacOS/SmartRoute" 2>/dev/null; then
            echo "App 版本    : 已是最新（/Applications/SmartRoute.app）"
        elif [ -n "$APPVER" ] && [ "$(printf '%s\n%s\n' "$NEWVER" "$APPVER" | sort -V | tail -1)" = "$APPVER" ]; then
            # 本地候选不比已装的更新——给复制命令就是让人降级。
            echo "App 版本    : 已安装 ${APPVER}，本地最新候选仅 ${NEWVER}，不提供降级命令"
            echo "              确要强制换成本地候选（会丢较新版本的改进）："
            echo "              rm -rf \"$APP\" && cp -R \"$NEWAPP\" /Applications/"
        else
            echo "⚠️  App 是旧版（已装 ${APPVER:-?} / 本地候选 ${NEWVER}）：刚才只更新了命令行部分，/Applications/SmartRoute.app 没动。"
            echo "    界面上看到的还是旧结论（比如旧的双网并发提示）。更新它："
            echo "      rm -rf \"$APP\" && cp -R \"$NEWAPP\" /Applications/"
            echo "      xattr -dr com.apple.quarantine \"$APP\""
        fi
    else
        echo "提示：本次没有可用的 App 构建产物（dist/ 下没有 SmartRoute.app）。"
        echo "      命令行部分已更新；要同步更新 App 先跑 bash build_release.sh。"
    fi
else
    echo "提示：未检测到 /Applications/SmartRoute.app（只装了命令行部分，这没问题）。"
    echo "      想要图形界面：bash build_dmg.sh 生成安装包，或解压 dist/ 里的 zip 拖入应用程序。"
fi
echo
echo "常用命令："
echo "  sudo smartroute status     # 查看当前状态（哪个接口在走、探测结果）"
echo "  sudo smartroute test -v    # 手动探测两个接口，看分层明细"
echo "  sudo smartroute set wifi   # 强制走 Wi-Fi（auto/ethernet/wifi/speed/latency）"
echo "  tail -f /var/log/smartroute.log   # 查看日志"
echo
if [ "$ALREADY" = "1" ]; then
    echo "升级完成，原有配置已保留。"
else
    echo "提示：默认 MODE=auto（哪个能用走哪个）。想指定「谁快走谁」，"
    echo "      用 sudo smartroute set speed；想两条一起走，用 sudo smartroute balance on。"
fi

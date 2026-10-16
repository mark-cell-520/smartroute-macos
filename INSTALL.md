# SmartRoute 安装说明

**Mac 双网智能选路工具** —— 网线 + Wi-Fi 同时在线时自动选路、双网并发分流、一键体检排障。

---

## 一、系统要求

| 项目 | 要求 |
|---|---|
| 系统 | macOS 13 (Ventura) 或更高，Apple Silicon / Intel 均可 |
| 网络 | 同时接入两条外网（例如：网线 + Wi-Fi）才能用「双网并发」 |
| 权限 | 「智能选路」「双网并发」需要管理员密码（系统会弹框，不会后台偷权限） |
| 空间 | 约 20 MB |

> 只有一条外网也能装：自动选路会在唯一可用的接口间保持通畅，只是没有"叠加带宽"的效果。

---

## 二、下载

到 GitHub Releases 页面下载最新版：

- **`SmartRoute-2.1-macOS.dmg`** —— 推荐，双击即可安装（本文重点）
- `SmartRoute-2.1-macOS.zip` —— 备用，解压后得到 `SmartRoute.app`

## 三、安装（DMG）

1. 双击打开 `SmartRoute-2.1-macOS.dmg`
2. 把 **SmartRoute** 拖到 **Applications** 快捷方式上（或拖到 Finder 侧栏的"应用程序"）
3. 等待拷贝完成，弹出（推出）磁盘映像，删除下载的 dmg 即可
4. 从"启动台"或"应用程序"文件夹打开 SmartRoute（菜单栏也会出现一个网络图标）

![安装示意](拖拽即安装)

## 四、首次打开：Gatekeeper 拦截怎么办

本工具**没有 Apple 开发者账号签名**，macOS 首次打开时会提示：

> "SmartRoute" 已损坏，无法打开 / 无法验证开发者

**这是正常现象，不是病毒。** 用下面任一方法解决：

### 方法 A：右键打开（推荐，只做一次）

1. 在"应用程序"里**右键点击** SmartRoute 图标
2. 在菜单里选「**打开**」
3. 在弹出的警告框里再点一次「打开」

之后永久正常打开，不再提示。

### 方法 B：终端清除隔离标记

```bash
xattr -dr com.apple.quarantine /Applications/SmartRoute.app
```

> 说明：`xattr -dr com.apple.quarantine` 只是删掉"这个文件来自网络"的标记，
> 不修改系统安全设置，也不需要关闭 SIP。

---

## 五、安装守护进程（关键一步）

App 打开后，顶部会出现蓝色横幅：**「守护进程需要更新 / 未安装」**。

守护进程是后台自动检测的小程序（每 20 秒一次），负责：

- 哪个接口通了就自动把默认路由切过去
- 双网并发开启后持续盯着，任一口断网立即自动还原
- 按你设的规则（如"公司内网走有线"）落地静态路由

**点横幅上的「更新守护进程」按钮**，输入管理员密码即可。装好后横幅消失。

> 不装守护进程也能用：所有功能都能手动点，只是不会自动切换/自动保护。

---

## 六、界面速览

左边侧栏九个页面，每页顶部有副标题说明用途：

| 页面 | 看/做什么 |
|---|---|
| 状态 | 谁在上网、网关通不通、服务顺序、切换历史 |
| 网速与延迟 | 实时速率曲线（每接口一条）+ 延迟丢包 |
| 双网并发 | 开启/关闭按连接分流；轮询或"最快线路"模式 |
| Wi-Fi 网络 | 附近网络扫描（信号排序）、一键切换、看真实协商速率；上不了网时自动换 |
| 分流规则 | 指定网段固定走某条线路（如公司内网走有线） |
| 选路设置 | 选路模式（自动/网速优先/延时优先/强制有线/强制 Wi-Fi）、实测结果、探测开关、判定阈值 |
| 体检 | 一键排查 + **导出诊断报告** |
| 日志 | 守护进程判定记录 + **导出日志** |
| 守护进程 | 安装/更新、**开机自启 App**、**彻底卸载（零残留）** |
| 关于 | 版本与致谢 |

常用操作：**选路设置页**可以「导出配置 / 导入配置」，把设置搬到另一台 Mac；
**体检页**的「导出诊断报告」会生成一份包含接口/路由/pf/配置/日志的纯文本，贴给别人就能排查。


## 七、命令行（可选）

装完守护进程后，终端里也有完整功能：

```bash
smartroute status                 # 当前状态：接口/网关/默认路由/切换历史
smartroute doctor                 # 一键体检：定位"为什么上不了网"
smartroute test -v                # 手动探测两个接口（-v 看分层明细）
smartroute config                 # 查看当前生效配置
sudo smartroute balance on        # 开启双网并发（轮询）
sudo smartroute balance on fastest# 开启双网并发（只走最快线路）
sudo smartroute balance status    # 查看并发状态与两边实时延迟
sudo smartroute balance off       # 关闭并恢复原状
smartroute set wifi               # 强制走 Wi-Fi（auto / ethernet / wifi）
smartroute log 100                # 看最近 100 行日志
smartroute fixconf                # App 提示"保存失败"时修配置属主（需 sudo）
smartroute set speed              # 网速优先：实测吞吐大的赢（也可 latency / auto / ethernet / wifi）
smartroute measurements          # 看上次实测的吞吐与延迟
sudo smartroute measure now       # 立即重新测量
sudo smartroute report > r.txt    # 一键诊断报告（贴给别人排查用）

# —— Wi-Fi 选择与自动切换 ——
smartroute wifi list             # 已保存的 Wi-Fi（免权限）
smartroute wifi scan             # 附近够得着的网络 + 信号强弱（免权限，约 10 秒）
smartroute wifi current          # 当前信号强度与信道（免权限）
smartroute wifi join CZ-305      # 一键切换到已保存的网络
smartroute wifi tryall           # 逐个试连，自动连上第一个能上网的
sudo smartroute wifi auto on     # Wi-Fi 上不了网时自动换网络
```

报告是纯文本，包含硬件接口、接口地址、IPv4 路由表、pf 状态与锚点规则、
两份配置、守护进程状态、状态文件、最近日志、双网并发状态。
里面的 IP 都是内网地址，不含密码或令牌，可以放心分享。

也可以在 App 里点「体检」页的**导出诊断报告**，会直接存到桌面。

---

## 八、卸载（零残留）

卸载脚本会一次清掉**所有**东西，卸完不留任何痕迹。它会清理：

| 类别 | 具体内容 |
|---|---|
| 守护进程 | 停止 launchd 服务 + 删 `/Library/LaunchDaemons/com.user.smartroute.plist` |
| pf 规则 | 刷掉 `com.apple/smartroute` 锚点里的分流规则 + 删锚点文件；**如果是本工具打开的 pf，会连 pf 一起关掉** |
| 路由 | 探测时添加的临时主机路由（按你配置的 `PROBE_TARGETS` 删，不限于默认那几个）+ 双网并发的静态网段路由 |
| 命令行 | `/usr/local/bin/smartroute` |
| 配置 | `/etc/smartroute.conf`、`/Users/Shared/smartroute.conf`（含 `.tmp` 残留）、`/Users/Shared/smartroute.rules` |
| 状态与日志 | `/var/db/smartroute`、`/var/log/smartroute.{log,out,err}`（含轮转的 `.1`）、`/var/run/smartroute.lock` |
| 服务顺序 | **会按备份还原**成安装前的网络服务顺序 |
| 临时文件 | `/tmp/.smartroute.probe.*` |
| App 本体 | `/Applications/SmartRoute.app` |

**方式一：App 内卸载**（推荐）

打开 App → 左侧「守护进程」页 → 底部「彻底卸载（零残留）」→ 点「彻底卸载…」，确认后会要一次管理员密码。
> App 内卸载会**保留 App 自身**（正在运行没法删自己），卸完你只需要把 `/Applications/SmartRoute.app` 拖进废纸篓。

**方式二：命令行卸载**

```bash
# 先看看会删什么（不动手）
sudo bash uninstall.sh --dry-run

# 正式卸载（会问你要不要删 App）
sudo bash uninstall.sh

# 不提问，全删（含 App）
sudo bash uninstall.sh --yes

# 想留着日志排查问题
sudo bash uninstall.sh --keep-logs
```

卸载完成后脚本会**自动校验**，输出「✅ 零残留」或列出遗漏项，确认文件、规则、路由、进程全都清干净了。

> 卸载后脚本会**如实报告**网络现状（默认路由走哪个接口、系统 pf 开还是关、
> 服务顺序有没有还原），你可以自己核对。
>
> 保留的东西：App 偏好与窗口状态在 `~/Library` 里，属你的个人数据，不会删；
> 导入配置前的备份 `smartroute.conf.bak` 也保留，路径会打出来，你自己决定。
>
> 本工具从来没有动过：DNS、VPN、系统代理、hosts。

---

## 九、常见问题

### Q1：提示"保存失败"

`/Users/Shared` 目录带 sticky 位，只有文件属主能替换它。早期版本的守护进程曾以 root
身份写过配置文件，导致之后存不进去。

**解决**：在 App 里再点一次「保存并生效」——失败会自动用管理员权限重试（弹一次密码框）。
或终端执行 `sudo smartroute fixconf`。

### Q2：开启双网并发提示"要求两个接口都有外网"

两个接口必须**都能上网**才允许开。用 `sudo smartroute test -v` 看哪边不通；
若只有一边能上，用「选路设置」切到能上的那个即可。

### Q3：两个接口网关相同，并发没提速？

如果以太网和 Wi-Fi 接的是**同一个路由器**（网关都是 192.168.1.1），
那本来就是同一条上网线路，分流只是把连接分给两块网卡，**总带宽不会变**。
要真正叠加带宽，需要两条独立外网（例如：网线接路由器 A + Wi-Fi 连手机热点）。
工具在检测到同网关时会给出 ⚠️ 提示。

### Q4：单线程下载没有变快？

双网并发是**按连接**分流的：一个下载连接固定走一个接口。
要让带宽叠加，需要多个并发连接/多个应用同时下载（浏览、云同步、多线程下载器都算）。

### Q5：VPN 下不能用双网并发？

是。VPN 会接管默认路由，与分流冲突。工具检测到 VPN 持有默认路由或全流量 VPN 时会
拒绝开启并提示；已开启时 VPN 接入也会触发自动还原。VPN 网段本身会被排除在分流之外。

### Q6：IPv6 不走分流？

是。当前只对 IPv4 的 TCP/UDP 做 `route-to` 分流，IPv6 走系统默认路由，不受影响。

### Q7：App 每次打开都要重新授权吗？

不用。同一台机器上，`do shell script ... with administrator privileges` 的授权会被记住。

### Q8：睡眠唤醒后失效？

macOS 睡眠唤醒可能重建默认路由。守护进程 20 秒内会自动修正；双网并发的 pf 规则丢失时
也会自动重新加载。

---

## 十、关于资源占用

- App 只在**前台可见时**做采集（每 5 秒一次 + 每秒网速采样）；切到别的 App 后
  子进程数会降到 0，不会在后台白烧电。切回前台会立刻补一次刷新。
- 守护进程是常驻的，每 20 秒探测一次，CPU 占用可忽略。
- 不想让 App 常驻：直接退出即可，选路状态会保留；需要自动切换再打开。
  > 注意：**退出 App 不会停掉自动选路**——自动选路由守护进程（launchd 的
  > 系统级服务）负责，跟 App 在不在前台无关，菜单栏图标消失只是看不见了。
  > 想真的暂停：App 的「守护进程」页有「暂停自动选路」按钮（临时，重启恢复），
  > 或在终端执行 `sudo launchctl bootout system/com.user.smartroute`。

## 十一、从源码构建（开发者）

```bash
git clone <你的仓库地址>
cd smartroute

bash build_release.sh  # 编译通用二进制 App（arm64 + x86_64）+ 校验 + 打 ZIP
bash build_dmg.sh      # 打 DMG（需在普通终端运行，沙箱内无法创建设备映像）

bash tests/mock_balance_rules.sh   # 跑测试（共 24 个测试文件，674 项断言）
```

> `build_dmg.sh` 需要在有设备访问权限的普通终端运行；在沙箱/CI 里会报
> `newfs_hfs: Operation not permitted`，这不是脚本问题。

---

## 许可

MIT License

# smartroute — macOS 有线/无线双网卡智能选路

## 解决什么问题

Mac 同时连接**以太网**（没有外网 / 网关不通）和 **Wi-Fi** 时，macOS 的选路规则是：
**"服务顺序"里第一个活跃的服务提供默认路由**。

以太网排在 Wi-Fi 前面时，所有流量都走进以太网那个没有外网的网关——
即使 Wi-Fi 明明能上网，系统也不会用，表现为"插上网线反而没网"。

`smartroute` 每 20 秒探测各个接口的外网连通性，自动调整服务顺序/默认路由：

| 以太网状态 | 结果 |
|---|---|
| 有外网 | 走以太网（其局域网网段路由保留，内网照样通） |
| 无外网 | 走 Wi-Fi 上网，内网流量仍然走以太网 |
| 以太网恢复 | 自动切回以太网 |

带滞回和冷却机制（连续 2 次成功才算可用、连续 3 次失败才算不可用、两次切换至少间隔 45 秒），不会来回横跳。

**还能做更多**（详见下文）：

- **双网并发**：两个接口都有外网时，用 pf 把不同连接分发到两个网关，带宽叠加（单线程不会翻倍）；
- **分流规则**：指定网段（如公司内网 10.0.0.0/8）固定走指定接口；
- **网速与延迟监控**：实时速率曲线 + 逐接口延迟/丢包；
- **图形界面 App**：SwiftUI 原生应用，9 个页面 + 菜单栏图标。

---

## 30 秒手动修复（不用装工具）

如果以太网**长期不需要**，最简单的办法是调整服务顺序，让 Wi-Fi 排在上面：

```bash
sudo networksetup -ordernetworkservices "Wi-Fi" "Thunderbolt Bridge" "Ethernet"
```

或者图形界面：**系统设置 → 网络 → 右下角 `…` → 设置服务顺序**，把 Wi-Fi 拖到最上面。

如果网线口彻底不用：**系统设置 → 网络 → 以太网 → 删除/停用该服务**。

---

## 安装工具（自动选路）

```bash
cd ~/Pictures/smartroute
sudo bash install.sh
```

安装内容：
- 脚本 → `/usr/local/bin/smartroute`
- 配置 → `/etc/smartroute.conf`
- 守护进程 → `/Library/LaunchDaemons/com.user.smartroute.plist`（每 20 秒运行一次，开机自启）

> 升级：改了脚本后重新跑一次 `sudo bash install.sh` 即可（plist 未变则无需重载）。

## 常用命令

```bash
sudo smartroute status          # 当前状态：各接口 IP/网关、默认路由、服务顺序、切换历史
sudo smartroute test -v         # 手动探测两个接口（-v 显示 ping/TCP/TLS 分层明细）
sudo smartroute doctor          # 一键体检：定位"为什么上不了网"
sudo smartroute config          # 查看当前生效配置
sudo smartroute watch           # 手动执行一次检测/切换
sudo smartroute set wifi        # 强制走 Wi-Fi（auto / ethernet / wifi）
smartroute log 100              # 查看最近 100 行日志
tail -f /var/log/smartroute.log # 实时看日志
```

### 双网并发 / 分流 / 监控（v2.1 新增）

```bash
# —— 双网并发：不同连接分别走两个接口（带宽叠加效果）——
sudo smartroute balance on      # 开启（自动验证，失败自动还原）
sudo smartroute balance status  # 查看状态与 pf 规则
sudo smartroute balance off     # 关闭并恢复原状

# —— 分流规则：指定网段固定走指定接口（静态路由）——
smartroute rule add 10.0.0.0/8 en0   # 公司内网段走有线（普通用户可写，无需密码）
smartroute rule list                 # 查看规则及生效情况
smartroute rule del 10.0.0.0/8       # 删除

# —— 监控 ——
smartroute stats                # 各接口累计收发字节（App 每秒采样算实时速率）
smartroute quality              # 逐接口测延迟/丢包（root 下按接口分别测）
```

> `balance on` 会做 10 个真实连接验证：只有全部成功、且流量确实分布到两个接口才算开启，
> 否则自动还原；任一口随后失去外网，守护进程 20 秒内自动关闭并发并还原。

卸载：

```bash
sudo bash ~/Pictures/smartroute/uninstall.sh
```

---

## 图形界面 App（SmartRoute.app）

除了命令行，还有一个原生 SwiftUI App（含应用图标 + 菜单栏图标），已在 `~/Pictures/smartroute/SmartRoute.app` 构建好并启动。

**侧边栏导航，9 个页面：**

| 页面 | 内容 |
|---|---|
| 状态 | 当前默认路由（含网关可达性）、以太网/Wi-Fi 卡片（IP/网关/服务名/探测结果）、服务顺序、一键刷新/立即检测；未装守护进程时显示安装引导 |
| 网速与延迟 | 每个活跃接口的**实时上下行速率 + 曲线**（每秒采样）、延迟/最低/最高/丢包（每 30 秒） |
| 双网并发 | 一键开启/关闭 pf 分流（需密码）、状态面板、**两个接口的实时曲线**（直观看到流量被分摊）、原理与限制说明、技术细节折叠面板 |
| 分流规则 | 规则列表（含生效状态徽标）、添加/删除（CIDR + 接口），**无需密码** |
| 选路设置 | 模式切换（自动/强制以太网/强制 Wi-Fi）、TLS 探测/通知/自动开 Wi-Fi 开关、防抖阈值，**保存无需密码** |
| 体检 | 一键运行 doctor，结果可复制 |
| 日志 | 实时查看 `/var/log/smartroute.log` 和守护进程输出，可清空 |
| 守护进程 | 安装/卸载/立即运行（需要管理员密码） |
| 关于 | 版本、工作方式、文件位置 |

菜单栏图标：快速切换模式（自动/Wi-Fi/以太网）、开关双网并发、打开面板。

**重新构建**（改了源码后）：

```bash
cd ~/Pictures/smartroute && bash build_app.sh
```

**使用建议**：把 `SmartRoute.app` 拖到 `/Applications` 或 `~/Applications`，以后从 Dock/启动台打开。
App 内的配置修改、分流规则都写入 `/Users/Shared/`（普通用户可写、root 守护进程可读），
所以改模式、加规则都不需要密码；只有"安装守护进程 / 立即检测 / 清空日志 / 开关双网并发"会弹系统密码框。

**权限说明**：首次打开如提示"无法验证开发者"，右键 → 打开即可（本地构建、已做 ad-hoc 签名）。

---

## 工作方式

1. **发现接口**：从 `networksetup -listallhardwareports` 找到当前活跃的以太网设备
   （en0、扩展坞的 en4/en5/en6 等都认）和 Wi-Fi 设备（en1）。
2. **探测外网**（三层，任一通过即算通）：
   - `ping` 公网 IP —— 快，但可能被防火墙禁 ICMP；
   - `TCP 53/443` —— 穿透大部分禁 ping 的网络；
   - `TLS 握手`（curl https://1.1.1.1）—— 识别"TCP 通但没有真正互联网"的场景。
   root 下给探测目标添加**临时主机路由**强制走指定接口，因此可以测出
   "当前不是默认路由"的那个接口到底有没有外网；测完立即删除路由。
3. **决策**：结合滞回计数得出 `eth_ok` / `wifi_ok`，按 `MODE`（默认 auto）决定默认路由应走哪个接口。
4. **执行切换**：
   - 首选：`networksetup -ordernetworkservices` 调整服务顺序（持久，网络重连后依然有效）；
   - 兜底：直接 `route delete/add default` 改路由表（立即生效）。
5. **保护机制**：
   - 默认路由由 VPN/拨号接口（utun/ppp）持有时**不干预**；
   - 两次切换至少间隔 45 秒（冷却），防止临界状态抖动。
6. **双网并发**（可选，`balance on`）：通过 pf 锚点把**新连接**按 round-robin 分发到两个网关——
   - 只对"新连接"生效，单线程传输不会翻倍；多连接/多应用会自然分摊；
   - 自动排除两个局域网网段、链路本地/组播、以及 VPN/拨号接口上的网段；
   - 两个接口同网段时不需要 NAT；不同网段会按出口接口做 NAT 修正源地址；
   - 开启前做 10 个真实连接 + 流量分布验证，失败自动还原；任一口掉线，守护进程 20 秒内自动关闭并还原。
7. **分流规则**（可选）：`smartroute.rules` 里每行 `CIDR 接口`，守护进程（root）落地为静态路由，
   优先级高于默认选路，适合"公司内网段固定走有线"这类需求。

## 可配置项（/etc/smartroute.conf 或 /Users/Shared/smartroute.conf）

| 项 | 默认 | 说明 |
|---|---|---|
| `MODE` | `auto` | `auto`=谁有外网走谁 / `ethernet`=强制有线 / `wifi`=强制无线 |
| `OK_N` / `FAIL_N` | 2 / 3 | 连续成功/失败多少次才改变判定 |
| `COOLDOWN` | 45 | 两次切换最小间隔（秒） |
| `PROBE_TARGETS` | 5 个公共 IP | 探测目标，可换成公司内网 IP |
| `PING_TIMEOUT` / `NC_TIMEOUT` | 800ms / 2s | 探测超时 |
| `TLS_PROBE` | 1 | 是否启用第三层 TLS 探测 |
| `NOTIFY` | 0 | 置 1 后，每次切换弹系统通知 |
| `AUTO_WIFI_POWER` | 0 | 置 1 后，以太网无外网且 Wi-Fi 被关闭时自动打开 Wi-Fi |
| `BALANCE` | 0 | 双网并发分流开关（由 `balance on/off` 维护，勿手改） |

配置文件位置：`/etc/smartroute.conf`（系统级）+ `/Users/Shared/smartroute.conf`（用户级，优先级更高，
App 和 `smartroute set` 默认写这里，**不需要 sudo**）。分流规则在 `/Users/Shared/smartroute.rules`。

修改示例：

```bash
echo 'NOTIFY=1' | sudo tee -a /etc/smartroute.conf
```

想改检测频率（默认 20 秒）：编辑 `/Library/LaunchDaemons/com.user.smartroute.plist`
里的 `StartInterval`，然后 `sudo launchctl kickstart -k system/com.user.smartroute`。

## 注意事项

- **同网段冲突**：如果以太网和 Wi-Fi 拿到的是同一网段（比如都是 192.168.1.x），
  路由会互相干扰，`status`/`doctor` 会给出 ⚠️ 提示，建议修改局域网网段。
- **休眠唤醒**：从睡眠唤醒后 macOS 可能重建默认路由，守护进程会在 20 秒内自动修正。
- **VPN**：VPN 客户端（utun）的路由优先级更高，本工具检测到后会主动避开。
- **门户认证**：需要网页登录的公共 Wi-Fi/局域网，用 `doctor` 的 [5] 项检测。
- **多块网卡**：同时插多块有线网卡时，以"当前默认路由所在的有线网卡"为优先对象。
- **双网并发的边界**：单线程不会加速；IPv6 不走分流；VPN 抢默认路由或全流量 VPN 会被拒绝开启
  （分流 VPN 网段会被自动排除）；两个接口在同一网段时效果最好。
- **我现在的网络实况参考**：en0=以太网 192.168.1.36、en1=Wi-Fi 192.168.1.5，两者同在 192.168.1.0/24，
  且本机有 split-tunnel VPN（utun4，100.64/16）——开启并发时会自动排除 VPN 网段。

## 文件说明

| 文件 | 作用 |
|---|---|
| `smartroute.sh` | 主脚本（bash 3.2 兼容，无第三方依赖） |
| `SmartRouteApp/` | SwiftUI App 源码（含 make_icon.swift 图标生成器） |
| `build_app.sh` | 一键编译打包成 `SmartRoute.app`（含图标） |
| `com.user.smartroute.plist` | launchd 守护进程配置（每 20 秒） |
| `install.sh` / `uninstall.sh` | 安装 / 卸载 |
| `/Users/Shared/smartroute.conf` | 用户级配置（免密修改） |
| `/Users/Shared/smartroute.rules` | 分流规则（免密修改，守护进程应用） |

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
sudo smartroute watch           # 手动执行一次检测/切换（once / run 是同义别名）
sudo smartroute set wifi        # 强制走 Wi-Fi（auto / ethernet / wifi / speed / latency）
smartroute log 100              # 查看最近 100 行日志
sudo smartroute report > r.txt  # 一键诊断报告（贴给别人排查用）
tail -f /var/log/smartroute.log # 实时看日志
```

### 双网并发 / 分流 / 监控（v2.2 新增）

```bash
# —— 双网并发：不同连接分别走两个接口（带宽叠加效果）——
sudo smartroute balance on            # 轮询：新连接在两个接口间交替，带宽可叠加
sudo smartroute balance on fastest    # 最快：只走延迟低的那条，变慢自动改道
sudo smartroute balance status        # 查看状态、pf 规则、两边实时延迟
sudo smartroute balance off           # 关闭并恢复原状

# —— 分流规则：指定网段固定走指定接口（静态路由）——
smartroute rule add 10.0.0.0/8 en0   # 公司内网段走有线（普通用户可写，无需密码）
smartroute rule list                 # 查看规则及生效情况
smartroute rule del 10.0.0.0/8       # 删除

# —— 监控 ——
smartroute stats                # 各接口累计收发字节（App 每秒采样算实时速率）
smartroute quality              # 逐接口测延迟/丢包（root 下按接口分别测）
```

### 选路模式：不只是"能上网"，还能按网速/延迟挑

`MODE` 控制选路策略，`smartroute set <模式>` 或 App 的「选路设置」页切换：

| 模式 | 行为 | 适合 |
|------|------|------|
| `auto` | 两个接口谁有外网就走谁，以太网恢复外网后自动切回 | 默认，只求不断网 |
| `speed` | 两边都能上网时，**实测下载吞吐**大的赢 | 网线只协商到 100M、Wi-Fi 更快 |
| `latency` | 两边都能上网时，**实测延迟**低的赢 | 游戏、视频会议 |
| `ethernet` | 只要以太网有外网就走以太网 | 有线优先 |
| `wifi` | 只要 Wi-Fi 有外网就走 Wi-Fi | 网线口是局域网/坏口 |

**为什么"网速优先"要实测，不看链路标称值？** 因为链路的标称值说明不了问题——
`networksetup -getMedia` 对 Wi-Fi 只回 `autoselect`（读不到），
而有线能读到（如 `100baseTX`）。虽然 `system_profiler` 里有 Wi-Fi 的真实
`Transmit Rate`，但它只是链路瞬时速率：弱信号下标称 1000M 的路由器
可能只跑到几十兆。所以只能两边各下载一点数据实测。实测有两个代价，都做了处理：

- **费流量**：结果缓存，默认 5 分钟才重测（`SPEED_RECHECK`）
- **耗时数秒**：两个接口**串行**测。并行会互相抢带宽，两个数都偏小

**不会来回横跳**：吞吐差距不到 30%（`SPEED_SWITCH_RATIO`）判平手，继续用当前线路。
实测这台机器：以太网 15.9 Mbps、Wi-Fi 10.7 Mbps，差 49%，所以走有线是对的——
尽管网线只协商到 100M，Wi-Fi 信号只有 2 格反而更慢。

```bash
smartroute measurements       # 看上次实测结果
sudo smartroute measure now   # 立即重新测量
```

### 附近网络扫描：免权限，也不打断连接

`smartroute wifi scan` 会告诉你**现在够得着哪些已保存网络、信号多强**：

```
在范围的已保存网络（按信号排序，越靠前越好）：
  CZ-305             -52 dBm（4/4 格）  信道 6
  CZ-BH-407          -60 dBm（3/4 格）  信道 1

确认不在范围的（旁边没有这些路由器，属正常）：
  m
  405-2
```

两个关键点：

- **不需要「定位服务」权限**。macOS 的通用 Wi-Fi 扫描拿不到 SSID（要权限），
  但**按指定 SSID 扫描**不需要——而我们只关心"已保存的网络在不在范围"。
- **不打断当前连接**。不像 `networksetup -setairportnetwork` 那样一切就断。

有了它，`tryall` 才能**按信号从强到弱**试，而不是按系统保存的任意顺序。

> 注意「确认不在范围」和「未能确认」是两回事。系统对扫描有约 5 秒冷却，
> 冷却期内问别的 SSID 会拿上次的缓存回答，可能被误判成不在范围。
> 所以工具只把"真扫过且确实没有"算不在范围；拿不准的老实说"未能确认"，
> 并且**照样会去试**——排序错了只是多花几秒，漏掉能用的网络才是真错。

### Wi-Fi 选择与自动切换（v2.2 新增）

```bash
smartroute wifi list             # 已保存的 Wi-Fi（靠前优先，免权限）
smartroute wifi current          # 当前信号强度与信道（免权限）
smartroute wifi join CZ-305      # 一键切换到已保存的网络（不用输密码）
smartroute wifi scan             # 看附近哪些已保存网络够得着、信号多强（约 10 秒）
smartroute wifi scan --quick     # 快速版（约 1 秒，部分结果可能未确认）
smartroute wifi tryall           # 逐个试连，按信号从强到弱，自动连上第一个能上网的
                                 # （当前已能上网时直接不动，不会把自己踢下线）
sudo smartroute wifi auto on     # Wi-Fi 上不了网时，自动换到其它可用网络
smartroute wifi auto status      # 看开关、优先列表、冷却时间
```

App 里对应「Wi-Fi 网络」页：当前信号格数、已保存网络一键连接、自动切换开关与优先列表。

**为什么不显示"附近有哪些网络"？** macOS 要「定位服务」权限才肯把附近 Wi-Fi 的名字给应用，
这个工具不为看个扫描结果去要定位权限，所以只列出**你保存过的网络**（密码在系统钥匙串里，
一键连接不需要再输）。要连新网络，先用屏幕右上角菜单栏的 Wi-Fi 图标连一次，之后这里就能一键切。

**自动切换什么时候动手？** 条件很严，宁可不动也不弄坏你正在用的网络：

| 条件 | 说明 |
|------|------|
| 开关已打开 | `smartroute wifi auto on` 或 App 里的开关 |
| Wi-Fi 确实上不了网 | 要经过滞回判定（连续多次探测失败），不是一次 ping 不通就切 |
| 以太网也没有外网 | 否则默认路由走有线，切 Wi-Fi 没有意义 |
| 没有强制走有线 | `MODE=ethernet` 时绝不动作 |
| 距上次尝试超过 2 分钟 | 防止在两个网络间来回跳 |

`wifi tryall`（App 里的「逐个试连」）同样有这个保护：**当前 Wi-Fi 已经能上网时，
它什么都不做**，直接告诉你"已经可以上网"。失败时也会把原因分类说清楚——
"不在范围"（旁边没这个路由器，属正常）、"找到了但连不上"（密码改过了）、
"能连上但没有外网"（可能要网页认证），而不是一律报"都没有外网"。

只会连接「已保存过」的网络，失败就试下一个，全都不行就等下一轮。

> `balance on` 会做 10 次 TCP 连接验证：要求至少 8 次成功，且流量确实走了预期接口
> （轮询模式要求两个接口的出站字节都增长，证明被分摊了；最快模式只要求赢家增长），
> 否则自动还原；任一口随后失去外网，守护进程 20 秒内自动关闭并发并还原。
> 注意验证必须走 TCP——pf 分流规则只作用于 `proto { tcp udp }`，用 ping 验证会永远测不到分流效果。
>
> **两种策略**：
> `round-robin`（默认）把新连接交替分给两个网关，多连接/多下载时带宽可叠加；
> `fastest` 先测两边延迟，只把更快的网关放进 `route-to`，守护进程每约 4 分钟重测，
> 某条线路变慢就自动改走另一条。macOS 的 pf 没有加权 pool
> （只有 round-robin/random/source-hash/bitmask），所以"选最快"是靠只放一个网关实现的，
> 不能按 7:3 这类比例分配。延迟差小于 `FASTEST_SWITCH_RATIO`（默认 20%）时判为"差距不明显"，
> 继续轮询而不是来回切；两边都测不到延迟时自动回退轮询。
>
> **两个接口的网关不同才有带宽叠加效果**。如果以太网和 Wi-Fi 接到同一个路由器
> （网关相同，例如都是 192.168.1.1），分流只是把连接分摊到两块网卡，总带宽不变——
> 这种情况用「选路设置」自动切换就够了。

卸载：

```bash
sudo bash ~/Pictures/smartroute/uninstall.sh
```

---

## 图形界面 App（SmartRoute.app）

左边侧栏九个页面：**状态 / 网速与延迟 / 双网并发 / 分流规则 / 选路设置 / 体检 / 日志 / 守护进程 / 关于**。
每页顶部有副标题说明用途；第一次打开且没装守护进程时会弹一次引导页。

几个省心设计：

- **失焦就停采**：切到别的 App 时定时器全停，切回来立刻补一次刷新，后台不烧电
- **自适应轮询**：网络状况稳定约半分钟后自动从 5 秒降到 10 秒一采，一有变化立刻回到 5 秒
- **状态页有「x 秒前更新」**：超过 30 秒变橙色，说明采集可能卡了
- **采集全在后台线程**，主线程不跑 shell，界面不会卡壳

实用工具：

| 在哪 | 能干什么 |
|---|---|
| 体检页 | 运行体检；**导出诊断报告**到桌面（含接口/路由/pf/配置/日志全量快照） |
| 选路设置页 | 改模式与阈值；**导出/导入配置**（纯文本，可搬到另一台 Mac） |
| 日志页 | 自动刷新；**导出日志** |
| 守护进程页 | 安装/更新守护进程；**开机自启 App**（让菜单栏图标随登录出现）；**彻底卸载（零残留）** |

### 分发给别人安装（一键 DMG）

```bash
bash build_release.sh  # 编译通用二进制（arm64 + x86_64）+ 校验 + 打 ZIP
bash build_dmg.sh      # 打 DMG（内含 App + Applications 快捷方式 + 背景图 + 安装说明）
```

> ⚠️ 发布**不要**用 `build_app.sh`——它只编译主机架构（在 Apple Silicon 机器上
> 产出 arm64-only），Intel 用户拿到会直接报"已损坏"。它仅用于本地开发调试。
> 正确顺序就是上面这两条；`build_dmg.sh` 依赖 `build_release.sh` 的产物。

DMG 里已带 `安装说明.txt`（内容同 [INSTALL.md](INSTALL.md)），用户双击 → 拖到
Applications → 右键打开（绕过 Gatekeeper）即可。**给用户的完整安装/使用/排障文档看
[INSTALL.md](INSTALL.md)**，那里包含系统要求、卸载步骤和 8 条 FAQ。

> `build_dmg.sh` 必须在普通终端运行：创建磁盘映像需要设备访问权限，沙箱/CI 里会报
> `newfs_hfs: Operation not permitted`（这是环境限制，不是脚本问题）。
>
> DMG 里的 Finder 窗口布局（图标位置/背景图）需要**终端被授权控制 Finder**：
> 系统设置 → 隐私与安全性 → 自动化 → 允许你的终端控制 Finder。没授权也能正常打出 DMG，
> 只是打开时窗口朴素一点，不影响拖拽安装。

**上传 GitHub**（一条命令搞定代码推送 + Release）：

```bash
bash sync-github.sh            # 首次：建仓库并推送（支持 gh CLI / 令牌 / 手动三种认证）
bash sync-github.sh release 2.2  # 之后每次发版：构建 ZIP+DMG、推代码、建 Release 上传产物
```

**重新构建**（改了源码后）：

```bash
cd ~/Pictures/smartroute && bash build_release.sh
```

**使用建议**：把 `SmartRoute.app` 拖到 `/Applications` 或 `~/Applications`，以后从 Dock/启动台打开。
App 内的配置修改、分流规则都写入 `/Users/Shared/`（普通用户可写、root 守护进程可读），
所以改模式、加规则都不需要密码；只有"安装守护进程 / 立即检测 / 清空日志 / 开关双网并发"会弹系统密码框。

**权限说明**：首次打开如提示"无法验证开发者"，右键 → 打开即可（本地构建、已做 ad-hoc 签名）。

### 分发给别人（发布版构建）

```bash
bash build_release.sh
```

产出在 `dist/`：

| 文件 | 说明 |
|---|---|
| `SmartRoute-2.2-macOS.zip` | **推荐分发格式**：解压后右键 → 打开（或拖到应用程序） |
| `SmartRoute-2.2-macOS.dmg` | 带「拖到应用程序」的安装镜像（需要磁盘镜像权限的环境才能生成） |
| `SmartRoute/安装说明.txt` | 随包附带的中文安装说明 |

发布版特性：
- **通用二进制**（Apple Silicon + Intel），**macOS 13.0+** 可运行；
- ad-hoc 签名（无需 99 美元开发者账号）；未做 Apple 公证，所以首次打开需要「右键 → 打开」一次；
- App 自给自足：装好后在 App 内一键安装 root 守护进程（弹系统密码框），无需再跑命令行。

### 同步到 GitHub

```bash
bash sync-github.sh          # 初始化仓库、提交、创建远端仓库并推送
```

脚本会按优先级自动选择认证方式：已登录的 `gh` CLI → `GITHUB_TOKEN` 环境变量 → 交互粘贴令牌 → 手动模式。
项目自带 gh 二进制（`.tools/`，首次运行 `sync-github.sh` 时会自动加入 PATH），也可以自己
`export PATH="$HOME/Pictures/smartroute/.tools/gh_*/bin:$PATH"` 后直接用 `gh`。

推送后发布产物：

```bash
bash build_release.sh
gh release create v2.2 dist/SmartRoute-2.2-macOS.zip \
    --title "SmartRoute v2.2" --notes-file README.md
```

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
| `BALANCE_MODE` | `round-robin` | 并发策略：`round-robin` 轮询两条 / `fastest` 只走最快 |
| `FASTEST_SWITCH_RATIO` | 20 | 判定"明显更快"的延迟差百分比，低于此值继续轮询不切换 |
| `FASTEST_RECHECK` | 12 | fastest 模式下守护进程重测延迟的轮询次数（每轮约 20 秒） |

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
  （分流 VPN 网段会被自动排除）；两个接口网关相同时不会提升带宽。
- **pf 实现细节**（排障时有用）：规则加载到锚点 `com.apple/smartroute`，挂在系统 `/etc/pf.conf`
  已有的 `anchor "com.apple/*"` 通配锚点下，**不需要改动 /etc/pf.conf**。
  macOS 的 pf 有两个语法限制，工具已适配：① `route-to` 必须写在 `from/to` 之前；
  ② 不支持 `match ... nat-to`，改用经典 `nat ... -> (接口)`；排除多个网段要用 `table <name> {...}`
  而不是 `{ ... }` 列表（列表不能取反）。每次生成规则都会用 `pfctl -n` 自校验语法，
  加载后还会回读规则集确认锚点真的生效（避免"加载成功但不匹配流量"）。
- **App 提示"保存失败"**：`/Users/Shared` 带 sticky 位，只有文件属主能替换它。早期版本的
  守护进程曾以 root 身份创建 `/Users/Shared/smartroute.conf`，之后普通用户（也就是 App）
  就再也存不进去。新版已从根上修掉：root 只写 `/etc/smartroute.conf`，万一写了用户级配置
  也会把属主归还给当前用户。已中招的三种自救：① 在 App 里再点一次「保存并生效」，
  失败会自动用管理员权限重试（弹一次密码框）；② `sudo smartroute fixconf`；
  ③ `sudo chown $(id -u) /Users/Shared/smartroute.conf`。
- **`unbound variable` 报错 / 输出里的路径变成空括号**：bash 3.2（macOS 自带版本）在 UTF-8 locale 下
  会把 `$VAR` 后面的多字节中文并进变量名。开了 `set -u` 的脚本会直接报
  `xxx?: unbound variable` 退出；没开的脚本则静默把值展开成空（显示成"已加载（）"）。
  修法是把这类位置的变量写成 `${VAR}`。全仓库已扫过一遍并修完（28 处）。
- **界面卡住不动（卡壳）**：三个原因叠加，已全部修掉：
  1. `refresh()` 原来直接在主线程上串行跑十来个 shell 命令（networksetup ×2、route、
     ifconfig ×N、networksetup -getinfo ×N、pgrep、ping），开机/切页面/每 5 秒刷新时
     主线程被占满 → 现已整体挪到后台线程，只把结果抛回主线程；
     并把每个接口一次的 `ifconfig` 合并成一次全量解析（少 N-1 个进程）。
  2. 慢命令没有防重入：网速采样每秒触发一次 `stats`、切页面触发 `balance status`（4-5 秒）
     和 `quality`（最长 30 秒），上次没跑完又触发一次就**进程越积越多**，机器越来越卡。
     现已加统一的 in-flight 守卫：同名操作同时只跑一个，跑得慢就跳过本次。
  3. `Privileged.run`（管理员密码框）原来在后台线程调 `NSAppleScript`，Apple 要求主线程，
     后台调会出现"界面转圈但密码框不弹"的假死 → 现已用 `main.sync` 搬回主线程。
  另外失焦时停掉每秒采样（`applicationDidResignActive`），切回再恢复。
- **后台白烧电**：5 秒定时采集 + 每秒网速采样在 App 失焦后仍全速运行。现已改成
  失焦即停（`guard NSApp.isActive`），实测失焦 12 秒后子进程数归零；切回前台时
  `applicationDidBecomeActive` 立刻补一次刷新，数据不会显示成过期的。
- **采集进程太多**：一次采集原本要十来个进程（每个接口各跑一次 ifconfig 和
  `networksetup -getinfo`）。现已合并为一次全量 `ifconfig` + 一次 `netstat -rn`，
  一次采集从十多个进程降到 5 个。
- **App 崩溃/闪退**：历史上 `Shell.run` 的超时处理有缺陷——命令超时时只 `terminate()`
  后睡 300ms，子进程还没退出就让 `Process` 析构，Foundation 会在 `-[NSConcreteTask dealloc]`
  抛异常直接让 App 崩掉（`balance status` 里的延迟测量变慢后必崩）。现已改成
  terminate → 等 2 秒 → SIGKILL → 等到真正退出，并配合并发读管道避免大输出死锁。
- **开启并发提示"要求两个接口都有外网"**：说明探测时有一边不通。可能原因：
  ① 网线口本身没外网（用 `sudo smartroute test -v` 确认）；② 与守护进程的自动检测撞车了，
  稍等几秒重试即可（脚本已加锁规避）；③ 上次探测被中断留下了残留路由，下次运行会自动清理。
- **我现在的网络实况参考**：en0=以太网 192.168.1.36、en1=Wi-Fi 192.168.1.5，两者同在 192.168.1.0/24
  且网关都是 192.168.1.1（同一个路由器），另有 split-tunnel VPN（utun4，100.64/16）——
  这种组态下并发分流没有带宽收益，自动选路才是正解；想体验并发需两个接口通往不同网关。

## 文件说明

| 文件 | 作用 |
|---|---|
| `smartroute.sh` | 主脚本（bash 3.2 兼容，无第三方依赖） |
| `SmartRouteApp/` | SwiftUI App 源码（含 make_icon.swift 图标生成器） |
| `build_app.sh` | 一键编译打包成 `SmartRoute.app`（含图标，**仅主机架构**，本地调试用） |
| `build_release.sh` | 编译**通用二进制** + 架构/签名校验 + 打 ZIP（发布用这个） |
| `com.user.smartroute.plist` | launchd 守护进程配置（每 20 秒） |
| `install.sh` / `uninstall.sh` | 安装 / 卸载 |
| `/Users/Shared/smartroute.conf` | 用户级配置（免密修改） |
| `/Users/Shared/smartroute.rules` | 分流规则（免密修改，守护进程应用） |

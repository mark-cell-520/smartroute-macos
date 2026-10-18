import SwiftUI
import Combine
import AppKit

// MARK: - 主容器（侧边栏导航）

struct MainView: View {
    @StateObject private var model = NetworkModel()
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private let qualityTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            // 侧边栏顶部放实时状态头（当前走哪条线）。放在 List 外面而不是
            // 塞进 List 的第一个 Section：List 的行高和选中态会把它压成
            // 和普通菜单项一个样，而它需要的是"始终醒目"。
            SidebarStatusHeader(model: model)
            List(selection: $model.page) {
                Section("监控") {
                    ForEach([AppPage.status, .speed, .balance, .wifi, .rules]) { p in
                        Label(p.title, systemImage: p.icon).tag(p)
                    }
                }
                Section("设置与工具") {
                    ForEach([AppPage.routing, .doctor, .log, .daemon, .about]) { p in
                        Label(p.title, systemImage: p.icon).tag(p)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
            .scrollContentBackground(.hidden)
        } detail: {
            Group {
                switch model.page {
                case .status:  StatusView(model: model)
                case .speed:   SpeedView(model: model)
                case .balance: BalanceView(model: model)
                case .wifi:    WifiView(model: model)
                case .rules:   RulesView(model: model)
                case .routing: RoutingView(model: model)
                case .doctor:  DoctorView(model: model)
                case .log:     LogView(model: model)
                case .daemon:  DaemonView(model: model)
                case .about:   AboutView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(model.page.title)
            .navigationSubtitle(model.page.subtitle)
        }
        .frame(minWidth: 820, minHeight: 580)
        .background(Color(nsColor: .underPageBackgroundColor))
        // 首次启动且守护进程还没装：弹一次引导页（老用户/已装的不打扰）
        .sheet(isPresented: Binding(
            get: { !ScriptLocator.daemonInstalled && !UserDefaults.standard.bool(forKey: "didSeeWelcome") },
            set: { if !$0 { UserDefaults.standard.set(true, forKey: "didSeeWelcome") } }
        )) {
            WelcomeView(model: model)
        }
        .onAppear {
            NetworkModel.shared = model
            model.refresh()
            model.loadRoutingConfig()
            model.loadBalance()
            model.loadRules()
            model.loadQuality()
            model.loadWifi()
            model.loadWifiFailover()
            model.loadMeasurements()
            model.startSpeedMonitor()
        }
        .onReceive(timer) { _ in
            // 失焦时完全不采集：5 秒一次、每次五六个进程，后台白烧电。
            // 切回前台时 applicationDidBecomeActive 会立刻补一次刷新，数据不会旧。
            guard NSApp.isActive else { return }
            // 自适应间隔：网络状况稳定时降频到 10 秒，一有变化立刻回到 5 秒
            guard model.shouldPoll() else { return }
            model.refresh()
            if model.page == .balance { model.loadBalance() }
            if model.page == .wifi { model.loadWifi() }
            if model.page == .rules { model.loadRules() }
            // 实测结果由守护进程缓存，App 只是读出来展示；只在相关页面读，别白起进程
            if model.page == .routing || model.page == .status { model.loadMeasurements() }
        }
        .onReceive(qualityTimer) { _ in
            guard NSApp.isActive else { return }
            if model.page == .speed { model.loadQuality() }
        }
    }
}

// MARK: - 状态页

/// 把设备名翻成人话（en0 -> 以太网）。
/// 原来是 StatusView 的私有方法，DaemonView 的 flap 提示也要用——
/// 提成文件级函数，避免在第二个视图里再抄一遍（抄的那份还会漏掉 VPN 分支）。
func deviceDisplayName(_ device: String, from interfaces: [InterfaceInfo]) -> String {
    guard !device.isEmpty else { return "无" }
    if let iface = interfaces.first(where: { $0.device == device }) {
        return "\(iface.role)（\(device)）"
    }
    if device.hasPrefix("utun") || device.hasPrefix("ppp") || device.hasPrefix("ipsec") {
        return "\(device)（VPN/拨号）"
    }
    return device
}

struct StatusView: View {
    @ObservedObject var model: NetworkModel

    private var ethInterface: InterfaceInfo? { model.snapshot.interfaces.first { $0.role == "以太网" } }
    private var wifiInterface: InterfaceInfo? { model.snapshot.interfaces.first { $0.role == "Wi-Fi" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapM) {
                if !ScriptLocator.daemonInstalled {
                    daemonBanner
                } else if model.installFailed || model.snapshot.daemonState == .stopped {
                    // 这一态以前不存在，于是它是唯一存活的"以为成功实际失败"路径：
                    // 横幅条件只看 plist 文件在不在，而 plist 在校验之前就 cp 进去了，
                    // 安装失败时横幅照样消失、状态页回到正常模样，用户几周后才发现
                    // 自动选路从未工作。现在把"已安装但没在跑"单独告警。
                    daemonNotRunningBanner
                } else if model.snapshot.daemonScriptOutdated {
                    daemonOutdatedBanner
                }
                positioningLine
                // 同网关警告放在状态页最前面。用户抱怨"故障转移没效果、
                // 双网并发也没效果"时，他正在看的就是这一页——结论必须出现在
                // 他眼前，不能只放在双网并发页等人翻到（原来就是那样，
                // 等于没说）。同时给出**唯一还有意义的动作**：同网关时两个接口
                // 仍可能有速率差，网速优先挑快的那条是实实在在的提升。
                if !model.snapshot.sameGateway.isEmpty {
                    Banner(icon: "exclamationmark.triangle.fill", color: .orange,
                           title: "两个接口走同一台路由器，故障转移在此网络下无效",
                           message: """
网线和 Wi-Fi 的网关都是 \(model.snapshot.sameGateway)，是同一台路由器出来的。

这意味着：
· 路由器出故障时两个接口一起断——自动选路没有可切换的目标
· 双网并发也不会变快（瓶颈在路由器后面那条上游）

还能做的（按实测收益排序）：
· 两个接口仍有速率差异时，用「选路模式 → 网速优先」挑更快的那条
· 想让两条线一起扛一个文件：用智能路由的 fetch 多连接下载。它按接口
  显式绑连接，不依赖 pf 分流，也没有 pf 分流的网络卡死风险

关于双接口在此网络下的真实收益：IPv4 出口是同一个，带宽不会叠加。
实测到的是稳定性——两条连接挤在同一条线上时，总有一条被饿到 10-20 秒；
分到两条线上后最慢 5 秒，波动系数从 48-69% 降到 12%。

⚠️ 「两条实时曲线同时起伏」不能证明流量被分摊：Wi-Fi 只要关联着就永远有
背景心跳（mDNS/ARP/DHCP/iCloud），pf 没生效时那一侧也「有流量」。
要看真实分摊，用 fetch 下载后读它打印的「实测分摊」。
""")
                }
                // 【链路能力差距】以太网协商速率远低于网卡能力时必须报警。
                // 用户看到「有线 100M、Wi-Fi 432M」就问为什么不能相加成 532M。
                // 真相是网卡能跑 2.5G、链路只谈到 100M，差的是网线或路由器端口。
                // 修好它一条有线就能跑满千兆宽带，比任何软件聚合都强。
                // 放在这里（默认落地页）而不是双网并发页：用户正在看的就是这页，
                // 结论放错页等于没说。这个坑本轮已经犯过一次。
                // 阈值与 smartroute.sh 的 cmd_status 必须一致（1000M）：宽带通常
                // 就是千兆，1000baseT 已跑满，此时报「网卡支持 2500M」是噪音——
                // 换了线也快不了，上游封死了。两边阈值不一致会出现"终端说有问题、
                // App 说没有"，用户不知道该信谁。
                if model.snapshot.ethNegotiatedMbps > 0,
                   model.snapshot.ethNegotiatedMbps < 1000,
                   model.snapshot.nicMaxMbps >= 1000 {
                    Card {
                        VStack(alignment: .leading, spacing: Theme.gapXS) {
                            Label("以太网只跑到 \(model.snapshot.ethNegotiatedMbps)M，网卡支持 \(model.snapshot.nicMaxMbps)M",
                                  systemImage: "cable.connector")
                                .font(.headline).foregroundStyle(.orange)
                            Text("""
                                这不是本工具的限制，是网线或路由器端口。100baseTX 只需要                                 2 对线通，1000baseT 要 4 对全通——线序坏一对就会掉到 100M。
                                """)
                                .font(.caption).foregroundStyle(.secondary)
                            Text("""
                                换一根 Cat5e 以上网线，或插到路由器千兆口。修好之后一条有线                                 即可跑满千兆宽带，强于任何两条线的软件聚合。
                                """)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                // 链路速率对比。只在同网关时显示——这正是它唯一有意义的场合，
                // 也与 NetworkModel 里的取值条件一致（不同网关时不取，省 1.7 秒）。
                if !model.snapshot.sameGateway.isEmpty,
                   !model.snapshot.linkSpeedEth.isEmpty || !model.snapshot.linkSpeedWifi.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: Theme.gapXS) {
                            Text("链路速率").font(.headline)
                            HStack(spacing: Theme.gapM) {
                                LabeledContent("以太网") {
                                    Text(model.snapshot.linkSpeedEth.isEmpty ? "未连接" : model.snapshot.linkSpeedEth)
                                        .monospaced()
                                }
                                LabeledContent("Wi-Fi") {
                                    Text(model.snapshot.linkSpeedWifi.isEmpty ? "未连接" : model.snapshot.linkSpeedWifi)
                                        .monospaced()
                                }
                            }
                            Text("协商速率是理论上限，实际速度还取决于对端设备与信号质量。")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                // 系统反复推翻我们的选择时，把这个数字亮出来。
                // 它必须放在**状态页**（默认落地页）而不是守护进程页——
                // 用户反馈"以太网卡主"时看的就是状态页，把证据放在另一个
                // 标签页里等于没说（同网关横幅当初就是放错了地方才改过来的）。
                // 这台机器实测 51 次 en0 -> en1：不是工具在抖，是 macOS
                // 每次都判回以太网。上面的横幅解释原因，这里给出证据。
                if model.snapshot.flapCount >= 3 {
                    Banner(icon: "arrow.triangle.2.circlepath", color: .orange,
                           title: "macOS 已 \(model.snapshot.flapCount) 次把默认路由改回 \(deviceDisplayName(model.snapshot.flapTarget, from: model.snapshot.interfaces))",
                           message: """
这不是工具在抖动，是系统反复把默认路由判回另一个接口。

常见原因是两个接口同网段或同网关（见上方提示）。工具每次都会把它改回来，
所以你可能感觉到"网莫名其妙断一下"——那正是切换的瞬间。

要减少这种反复：调整局域网网段，让两个接口走不同网段。
""")
                }
                defaultRouteCard
                HStack(alignment: .top, spacing: Theme.gapM) {
                    InterfaceCard(iface: ethInterface, role: "以太网", icon: "cable.connector",
                                  probe: model.snapshot.ethOK, streak: model.snapshot.streakEth)
                    InterfaceCard(iface: wifiInterface, role: "Wi-Fi", icon: "wifi",
                                  probe: model.snapshot.wifiOK, streak: model.snapshot.streakWifi)
                }
                serviceOrderCard
                if let watchResult = model.watchResult {
                    Card(title: "上次手动检测输出") {
                        Text(watchResult)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(Theme.gapL)
        }
    }

    /// 工具定位的一句话。
    ///
    /// 这句大白话原来只在欢迎页和 README 里。而从命令行装守护进程的用户
    /// **永远看不到欢迎页**（sheet 条件是 !daemonInstalled && !didSeeWelcome），
    /// 直接面对满屏"默认路由/服务顺序"黑话——产品最好的解释恰好被跳过了。
    /// 所以在这里也放一份。
    private var positioningLine: some View {
        HStack(spacing: Theme.gapXS) {
            Image(systemName: "cable.connector")
                .font(.caption)
            Text("插上网线自动走网线，网线没外网自动切 Wi-Fi，恢复后自动切回。")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.gapXS)
    }

    private var daemonBanner: some View {
        Banner(icon: "exclamationmark.triangle.fill", color: Theme.warn,
               title: "守护进程尚未安装",
               message: "安装后每 20 秒自动检测：以太网没有外网时自动切到 Wi-Fi，恢复后自动切回（开机自启）",
               buttonTitle: model.daemonInstalling ? nil : "安装守护进程") {
            model.installDaemon()
        }
    }

    /// 已安装但没在跑。最常见的原因就是安装时 launchctl 那步失败了——
    /// 而 install.sh 现在已经会验证并报错，这里把结论呈现给用户。
    private var daemonNotRunningBanner: some View {
        Banner(icon: "xmark.octagon.fill", color: Theme.bad,
               title: model.installFailed ? "守护进程安装失败" : "守护进程未在运行",
               message: model.installFailed
                   ? "自动选路没有生效。下面的输出里有失败原因和手动排查命令，照着做即可。"
                   : "守护进程已安装但没在跑，自动选路不会发生。可在终端执行：sudo launchctl bootstrap system /Library/LaunchDaemons/com.user.smartroute.plist",
               buttonTitle: model.daemonInstalling ? nil : "重试安装") {
            model.installDaemon()
        }
    }

    /// 守护进程的脚本比 App 旧：App 功能照常跑（用内置脚本），但自动选路还是旧逻辑
    private var daemonOutdatedBanner: some View {
        Banner(icon: "arrow.triangle.2.circlepath.circle.fill", color: Theme.info,
               title: "守护进程需要更新",
               message: "已安装的守护进程脚本比当前 App 旧，自动选路/探测判定可能不准确。点右侧同步（会要一次管理员密码）。",
               buttonTitle: model.daemonInstalling ? nil : "更新守护进程") {
            model.installDaemon()
        }
    }

    private var defaultRouteCard: some View {
        Card {
            HStack(spacing: Theme.gapM) {
                ZStack {
                    Circle()
                        .fill((model.snapshot.defaultReachable ? Theme.ok : Theme.warn).opacity(0.14))
                        .frame(width: 52, height: 52)
                    Image(systemName: model.snapshot.defaultReachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(model.snapshot.defaultReachable ? Theme.ok : Theme.warn)
                    // 断网/恢复时颜色平滑过渡，不刺眼
                    .animation(.easeInOut(duration: 0.35), value: model.snapshot.defaultReachable)
                }
                VStack(alignment: .leading, spacing: Theme.gapXS) {
                    // 主标题说人话。"当前默认路由"是术语，普通用户看到不知道
                    // 这跟自己有什么关系。他真正想知道的是"我现在走的哪条线"。
                    // via <网关IP> 那行留给需要的人，放在副标题位置。
                    Text("正在通过：\(deviceDisplayName(model.snapshot.defaultDevice, from: model.snapshot.interfaces))").font(.headline)
                    Text("默认路由  \(model.snapshot.defaultDevice.isEmpty ? "?" : model.snapshot.defaultDevice)   via   \(model.snapshot.defaultGateway.isEmpty ? "?" : model.snapshot.defaultGateway)")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: Theme.gapXS) {
                        Pill(text: model.snapshot.gatewayUnknown
                             ? "网关状态未知"
                             : (model.snapshot.defaultReachable ? "网关可达" : "网关不可达"),
                             // 未知时用中性色。以前未知也按"不可达"涂成警示色，
                             // 而禁 ping、VPN 虚拟网关、同网段直连都是正常情况——
                             // 用户上着网被一个红字吓到，比不显示更糟。
                             color: model.snapshot.gatewayUnknown ? Theme.idle
                                 : (model.snapshot.defaultReachable ? Theme.ok : Theme.warn))
                        FreshnessBadge(since: model.snapshot.lastUpdatedAt)
                        Text("最近切换 \(model.snapshot.lastSwitch)（共 \(model.snapshot.switchCount) 次）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(spacing: Theme.gapS) {
                    Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    Button { runWatch() } label: { Label("立即检测", systemImage: "play.fill") }
                        .disabled(model.watchRunning)
                }
                .controlSize(.small)
            }
        }
    }

    private var serviceOrderCard: some View {
        Card(title: "服务顺序", subtitle: "越靠前越优先") {
            if model.snapshot.services.isEmpty {
                EmptyState(icon: "list.bullet", title: "暂无网络服务", message: nil)
            } else {
                VStack(alignment: .leading, spacing: Theme.gapS) {
                    ForEach(model.snapshot.services) { svc in
                        HStack {
                            Text(svc.name)
                            if !svc.enabled { Pill(text: "已禁用", color: Theme.idle) }
                            Spacer()
                            if svc.device == model.snapshot.defaultDevice {
                                Pill(text: "当前默认", color: Theme.brand, icon: "star.fill", filled: true)
                                    .transition(.scale.combined(with: .opacity))
                            }
                            Text(svc.device).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: model.snapshot.defaultDevice)
            }
        }
    }


    private func runWatch() {
        model.watchRunning = true
        model.runWatch { ok, out in
            model.watchRunning = false
            model.watchResult = (ok ? "" : "失败: ") + out
            model.refresh()
        }
    }
}

// MARK: - 接口卡片

struct InterfaceCard: View {
    let iface: InterfaceInfo?
    let role: String
    let icon: String
    let probe: String
    let streak: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                HStack {
                    Image(systemName: icon).font(.title2).foregroundStyle(Theme.brand)
                    Text(role).font(.headline)
                    Spacer()
                    ProbePill(value: probe, streak: streak)
                        // 探测判定从"检测中"变成"有/无外网"时淡入，不要硬跳
                        .animation(.easeOut(duration: 0.28), value: probe)
                }
                if let iface, iface.active {
                    KeyValueRow(key: "设备", value: iface.device, monospaced: true)
                    KeyValueRow(key: "IP", value: iface.ip, monospaced: true)
                    KeyValueRow(key: "网关", value: iface.gateway, monospaced: true)
                    KeyValueRow(key: "服务", value: iface.service)
                    // 脚本的 streak 是带符号的：ok 正、fail 负、未知=0。
                    // 以前原样显示，负数会印出"连续探测 -3 次"——读起来像 bug。
                    KeyValueRow(key: "连续探测", value: streakText(streak))
                } else {
                    EmptyState(icon: "cable.connector.slash",
                               title: "未连接",
                               message: "插上线后会自动出现在这里")
                }
            }
        }
    }
}

/// streak 的展示：脚本语义是"ok 正数 / fail 负数 / 未知 0"。
/// 负数要显示成"连续失败 N 次"而不是 "-3 次"。
struct ProbePill: View {
    let value: String
    var streak: String = ""

    /// 连续探测计数为 0 表示判定尚未确立（探测被中断/结果异常/接口未激活），
    /// 此时沿用的旧判定不可信，应显示"未知"而不是"有/无外网"。
    private var effective: String {
        if streak == "0" { return "-" }
        return value
    }

    private var text: String {
        switch effective {
        case "1": return "有外网"
        case "0": return "无外网"
        case "-": return "未知"
        default: return effective
        }
    }

    private var color: Color {
        switch effective {
        case "1": return Theme.ok
        case "0": return Theme.bad
        default: return Theme.idle
        }
    }

    var body: some View {
        Pill(text: text, color: color)
    }
}

// MARK: - 网速与延迟页

struct SpeedView: View {
    @ObservedObject var model: NetworkModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapM) {
                if model.monitoredDevices.isEmpty {
                    Card {
                        Text("没有检测到活跃接口")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                }
                ForEach(model.monitoredDevices, id: \.self) { dev in
                    SpeedCard(model: model, dev: dev)
                }
                qualityCard
                // 用户装完最想知道的是"网变快了吗"。原来这页只有实时曲线，
                // 没有基线也没有对比——没下载时曲线贴近 0，用户反而觉得没变快。
                // 这里直接给出结论，并说清曲线为什么有时是平的。
                answerCard
                hintCard
            }
            .padding()
        }
        .onAppear { model.loadQuality() }
    }

    /// 直接回答"网变快了吗"。
    ///
    /// 这一页原来只有实时曲线，而曲线的语义普通人读不出来：没下载的时候
    /// 贴近 0 是正常的，用户却以为"没变快/变慢了"。而且这工具**不会**
    /// 让宽带本身变快——它只是在两条线路里挑一条。这个预期必须在这里说清，
    /// 否则用户会一直等一个不会发生的结果。
    private var answerCard: some View {
        Card(title: "网变快了吗？") {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                Text("这个工具不会让你的宽带本身变快——它只是在以太网和 Wi-Fi 两条线路里，挑一条更快/更稳的来走。")
                    .font(.callout)
                Text("所以「变快」只发生在这种情况：你原来走的那条更慢，切换后走上了更快的那条。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("曲线为什么有时是平的？")
                    .font(.caption).foregroundStyle(.secondary)
                Text("曲线是实时网速，没有下载任务时接近 0 是正常的——不代表网变慢了。想看峰值，随便下载个文件就能看到起伏。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var qualityCard: some View {
        Card(title: "延迟与丢包", subtitle: "每 30 秒更新；root 下按接口分别探测") {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                if model.quality.isEmpty {
                    Text("测量中…").foregroundStyle(.secondary)
                }
                ForEach(["eth", "wifi"], id: \.self) { role in
                    if let q = model.quality[role] {
                        HStack {
                            Image(systemName: role == "eth" ? "cable.connector" : "wifi")
                                .frame(width: 20)
                            Text(role == "eth" ? "以太网" : "Wi-Fi").frame(width: 60, alignment: .leading)
                            Text(q.dev).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                            Spacer()
                            qualityValue(label: "延迟", value: "\(q.avg) ms")
                            qualityValue(label: "最低", value: "\(q.min) ms")
                            qualityValue(label: "最高", value: "\(q.max) ms")
                            qualityValue(label: "丢包", value: q.loss, color: q.loss == "0.0%" ? .green : .orange)
                        }
                    }
                }
            }
        }
    }

    private func qualityValue(label: String, value: String, color: Color = .primary) -> some View {
        VStack(spacing: Theme.gapXS) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).foregroundStyle(color)
        }
        .frame(minWidth: 56)
    }

    private var hintCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                // 三处修正，都是实测出来的，不是措辞润色：
                //
                // 1) 原来写"唯一办法是去开 pf 分流"。不对——smartroute fetch -n N
                //    按 --interface 显式绑接口，不依赖 pf 也能让两条线一起扛。
                //    而同网关拓扑下 pf 分流没有带宽收益，还有网络卡死风险
                //    （实测发生过：加载规则后整个网络不通，要 balance off 才恢复）。
                //    把用户往唯一那条又有风险又没收益的路上引，是不对的。
                //
                // 2) 原来写"两条曲线同时起伏即证明流量被分摊"。这是**假证据**：
                //    Wi-Fi 只要关联着就永远有背景流量（mDNS/ARP/DHCP/iCloud 心跳），
                //    实测几百字节起步。pf route-to 根本没生效时那一侧也"有流量"。
                //    balance_validate 当初就是为这个才把门槛提到 64KB+10% 的，
                //    而这里却在教用户看那个假信号——自相矛盾。
                //
                // 3) 同网关（同一台路由器）时 IPv4 出口是同一个，两条线不是两条 WAN。
                //    实测收益不在带宽叠加，在把抖动的尾巴消掉（两条连接挤一条线时
                //    总有一条被饿到 10-20 秒，分到两条线上最慢 5 秒，波动系数
                //    48-69% 降到 12%）。说清楚，用户才不会为不存在的带宽失望。
                Label("想让两条线一起扛一个文件？用智能路由的 fetch 多连接下载。", systemImage: "arrow.triangle.branch")
                    .font(.callout)
                Text("它按接口显式绑连接，不依赖 pf 分流，也不会有 pf 分流的网络卡死风险。")
                    .font(.caption).foregroundStyle(.secondary)

                // 同网关优先取 snapshot 的（每次刷新都有，不用等用户翻开并发页）；
                // 它为空时再退回 balance status 解析出来的那个。
                let sameGw = model.snapshot.sameGateway.isEmpty
                    ? model.balanceSameGateway : model.snapshot.sameGateway
                if !sameGw.isEmpty {
                    Label("你的两个接口网关相同（\(sameGw)），不是两条 WAN。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("IPv4 走同一个上游出口，带宽不会叠加。实测收益是稳定性：分到两条线上后，慢尾巴从 10-20 秒降到 5 秒以内。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Text("曲线同时起伏不能证明流量被分摊——Wi-Fi 关联着就永远有背景心跳。要看真实分摊，用 fetch 下载后读它打印的「实测分摊」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SpeedCard: View {
    @ObservedObject var model: NetworkModel
    let dev: String

    private var role: String {
        model.snapshot.interfaces.first { $0.device == dev }?.role ?? dev
    }
    private var icon: String { role == "Wi-Fi" ? "wifi" : "cable.connector" }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                HStack {
                    Image(systemName: icon).font(.title3)
                    Text("\(role)（\(dev)）").font(.headline)
                    Spacer()
                    HStack(spacing: Theme.gapM) {
                        Label(formatSpeed(model.speedIn[dev] ?? 0), systemImage: "arrow.down")
                            .foregroundStyle(.green)
                            .font(.system(.callout, design: .monospaced))
                        Label(formatSpeed(model.speedOut[dev] ?? 0), systemImage: "arrow.up")
                            .foregroundStyle(.blue)
                            .font(.system(.callout, design: .monospaced))
                    }
                }
                HStack(spacing: Theme.gapS) {
                    Sparkline(values: model.historyIn[dev] ?? [], color: .green)
                        .frame(height: 40)
                    Sparkline(values: model.historyOut[dev] ?? [], color: .blue)
                        .frame(height: 40)
                }
                HStack {
                    Text("下载曲线").font(.caption2).foregroundStyle(.green)
                    Spacer()
                    Text("上传曲线").font(.caption2).foregroundStyle(.blue)
                }
            }
        }
    }

    private func formatSpeed(_ kbps: Double) -> String {
        if kbps >= 1024 { return String(format: "%.1f MB/s", kbps / 1024) }
        if kbps >= 1 { return String(format: "%.0f KB/s", kbps) }
        return "0 KB/s"
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.06))

                if values.count > 1 {
                    // 面积填充：让曲线有体积感，读起来更直观
                    Path { p in
                        let maxV = max(values.max() ?? 1, 1.0)
                        let w = geo.size.width, h = geo.size.height
                        p.move(to: CGPoint(x: 0, y: h))
                        for (i, v) in values.enumerated() {
                            let x = w * CGFloat(i) / CGFloat(values.count - 1)
                            let y = h - max(1, h * CGFloat(v / maxV))
                            p.addLine(to: CGPoint(x: x, y: y))
                        }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.22), color.opacity(0.0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                    // 折线用 Catmull-Rom 平滑，去掉锯齿感
                    Path { p in
                        let maxV = max(values.max() ?? 1, 1.0)
                        let w = geo.size.width, h = geo.size.height
                        let pts = values.enumerated().map { i, v -> CGPoint in
                            CGPoint(x: w * CGFloat(i) / CGFloat(values.count - 1),
                                    y: h - max(1, h * CGFloat(v / maxV)))
                        }
                        p.move(to: pts[0])
                        for i in 1..<pts.count {
                            let p0 = pts[max(0, i - 2)]
                            let p1 = pts[i - 1]
                            let p2 = pts[i]
                            let p3 = pts[min(pts.count - 1, i + 1)]
                            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                            p.addCurve(to: p2, control1: c1, control2: c2)
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }

                // 最新值点
                if let last = values.last, let maxV = values.max(), maxV > 0 {
                    let x = geo.size.width
                    let y = geo.size.height - max(1, geo.size.height * CGFloat(last / maxV))
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                        .position(x: x - 3, y: y)
                        .shadow(color: color.opacity(0.5), radius: 3)
                }
            }
            .animation(.easeOut(duration: 0.35), value: values.count)
        }
    }
}

// MARK: - 双网并发页

struct BalanceView: View {
    @ObservedObject var model: NetworkModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapM) {
                if !model.balanceSameGateway.isEmpty {
                    // 文案要跟上脚本的新行为：同网关时 --force 也不再放行。
                    // 原来这里只写"没有收益、建议关闭"，而脚本还有 --force 口子，
                    // 用户从终端强开后网络卡死（已报告两次）。现在脚本一律拒绝，
                    // 这里要说清"试了也会被拒"，并给出真正有用的替代动作。
                    Banner(icon: "exclamationmark.triangle.fill", color: .orange, title: "双网并发在此网络下没有收益", message: "网线和 Wi-Fi 的网关都是 \(model.balanceSameGateway)，是同一台路由器出来的——这不是两条 WAN，而是一条 WAN 的两个入口。\n\n分流不会变快（瓶颈在路由器后面那条上游），反而会把一半连接赶到更慢的接口；强开还会让网页卡壳（回包走错接口被 pf 状态表丢弃）。\n\n所以这个组合已被禁用，从终端加 --force 也会被拒绝。\n\n想让两条线一起扛一个文件：用「网速与延迟」页的 fetch 多连接下载，它显式绑接口、不依赖 pf。")
                }
                statusCard
                controlCard
                liveCard
                explainCard
                if !model.balanceStatusText.isEmpty {
                    DisclosureGroup("技术细节（pf 规则与状态）") {
                        Text(model.balanceStatusText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                }
            }
            .padding()
        }
    }

    private var statusCard: some View {
        Card(title: "并发分流状态") {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                HStack {
                    // 读不到状态时说"未知"，别拿上次的值冒充现值，更别猜"未开启"——
                    // 那会让用户去点"开启"，实际把正在跑的 pf 规则关掉。
                    if model.balanceUnknown {
                        statusDot(on: false, text: "状态未知，点击右侧重试")
                    } else {
                        statusDot(on: model.balanceOn, text: model.balanceOn ? "已开启" : "未开启")
                    }
                    Spacer()
                    if model.balanceLoading { ProgressView().controlSize(.small) }
                }
                LabeledContent("配置开关", value: "BALANCE=\(model.balanceOn ? 1 : 0)")
                // weighted 不能显示成"轮询两条"：容量配比下两边连接数可能差 4 倍，
                // 说成轮询会让用户排查时完全对不上。配比要一并显示。
                LabeledContent("分流策略", value: model.balanceStrategyLabel)
                LabeledContent("系统 pf", value: pfLine)
                LabeledContent("分流规则", value: ruleLine)
            }
        }
    }

    private var pfLine: String {
        for line in model.balanceStatusText.components(separatedBy: "\n") {
            if line.contains("系统 pf") {
                return line.replacingOccurrences(of: "系统 pf", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return "读取中…"
    }

    private var ruleLine: String {
        for line in model.balanceStatusText.components(separatedBy: "\n") {
            if line.contains("分流规则") {
                return line.replacingOccurrences(of: "分流规则", with: "").replacingOccurrences(of: ":", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "读取中…"
    }

    private func statusDot(on: Bool, text: String) -> some View {
        HStack(spacing: Theme.gapXS) {
            Circle().fill(on ? Theme.ok : Theme.idle).frame(width: 10, height: 10)
            Text(text).font(.headline)
        }
    }

    private var controlCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                Text(model.balanceOn
                     ? model.balanceStrategyBlurb
                     : "开启后，不同的网络连接会分别走以太网和 Wi-Fi。")
                    .font(.callout)

                // 策略选择：轮询分摊 vs 只走最快
                if !model.balanceOn {
                    Picker("分流策略", selection: $model.pendingBalanceMode) {
                        Text("轮询两条线路").tag("round-robin")
                        Text("只走最快线路").tag("fastest")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // 各接口实时延迟（选"最快"时就是靠它决定走哪条）
                if !model.balanceLatency.isEmpty {
                    HStack(spacing: Theme.gapM) {
                        ForEach(model.monitoredDevices, id: \.self) { dev in
                            Label("\(roleName(dev)) \(model.balanceLatency[dev] ?? "—")",
                                  systemImage: "timer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Button(model.balanceOn ? "关闭双网并发" : "开启双网并发") {
                        model.setBalance(on: !model.balanceOn, mode: model.balanceOn ? nil : model.pendingBalanceMode)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.balanceOn ? .red : .green)
                    .disabled(model.balanceLoading)
                    if !model.balanceMessage.isEmpty {
                        // 不能限行。balance on 被拒绝时的理由是一整段
                        // （同网关说明 + 卡死风险 + 该跑什么命令），
                        // lineLimit(2) 会把它砍成两句看不懂的残句——
                        // 而那正是用户唯一能看到拒绝原因的地方。
                        Text(model.balanceMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                if model.balanceOn {
                    Text(model.balanceMode == "fastest"
                         ? "守护进程会定期重测两边延迟，某条线路变慢就自动改走另一条。"
                         : (model.balanceMode == "weighted"
                            ? "守护进程约每 10 分钟重测一次吞吐并调整配比；Wi-Fi 变慢会自动把配比调回来，否则会出现「开了并发比不开还慢」。"
                            : "撤销会清空分流规则；如果 pf 是由本工具开启的，撤销时也会把系统 pf 关回去。"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("轮询：多连接/多下载在两个接口间均分，适合两条线差不多快。\n配比：按实测吞吐分配，适合两条线差得远（如 100M 有线配 432M Wi-Fi）。\n最快：所有新连接走延迟低的那条，适合一条稳一条快的场景。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var liveCard: some View {
        // 标题原来写的是"实时流量（两个接口一起动 = 分流生效）"和
        // "实时流量（只有一条在动 = 正在走最快线路）"。
        //
        // 这两句是**假证据**，而且是本项目专门修过一次的那一类：
        // Wi-Fi 只要关联着就永远有背景流量（mDNS/ARP/DHCP/iCloud 心跳），
        // pf route-to 根本没生效时，两条曲线照样一起起伏。于是用户盯着
        // 这个页面、看到曲线在动，就认定分流生效、结束排查——而 pf 规则
        // 可能压根没加载。
        //
        // smartroute.sh 的 balance_validate 早就为此把门槛提到 64KB+10%
        // （VALIDATE_MIN_BYTES，注释原话"低于此更可能是背景心跳，不是
        // 分流生效"），StatusView 和 SpeedView 也都在 6ed5eae 里加了警告，
        // 唯独漏了这里——而这是用户开启 pf 分流后**真正盯着的页面**。
        //
        // 曲线只回答"有没有流量"，不回答"流量是怎么被分流的"。
        // 后者只能看权威状态（同页 statusCard）或 fetch 打印的实测分摊。
        Card(title: "实时流量") {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                ForEach(model.monitoredDevices, id: \.self) { dev in
                    HStack {
                        Text(roleName(dev)).frame(width: 80, alignment: .leading)
                        Sparkline(values: model.historyIn[dev] ?? [], color: .green).frame(height: 22)
                        Sparkline(values: model.historyOut[dev] ?? [], color: .blue).frame(height: 22)
                        Text("↓ \(fmt(model.speedIn[dev] ?? 0))   ↑ \(fmt(model.speedOut[dev] ?? 0))")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 190, alignment: .trailing)
                    }
                }
                if model.monitoredDevices.isEmpty {
                    Text("暂无活跃接口").foregroundStyle(.secondary)
                }
                // 警告必须放在曲线旁边，不能只放在默认落地页：用户正在
                // 这个页面上判断"分流到底生没生效"，把提醒放到另一个标签页
                // 等于没说。
                Text("曲线同时起伏不能证明流量被分摊——Wi-Fi 只要关联着就永远有背景心跳（mDNS/ARP/DHCP/iCloud）。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("要看真实分摊：看上面的「分流状态」，或用 fetch 下载后读它打印的「实测分摊」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func roleName(_ dev: String) -> String {
        model.snapshot.interfaces.first { $0.device == dev }?.role ?? dev
    }

    private func fmt(_ kbps: Double) -> String {
        if kbps >= 1024 { return String(format: "%.1f MB/s", kbps / 1024) }
        return String(format: "%.0f KB/s", kbps)
    }

    private var explainCard: some View {
        Card(title: "原理与限制", subtitle: "务必阅读") {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                // 第一条必须是最关键的前提。原来卡片从"不同连接走不同接口"讲起，
                // 读者会以为家里那台路由器（网线+Wi-Fi 都接它）就能叠加——
                // 而绝大多数家庭正是这种情况，开了只会更慢。
                point("⚠️", "前提是你有**两条独立的宽带/WAN**（比如两条运营商线、或一条宽带 + 手机热点）。只有一条宽带的话，网线和 Wi-Fi 都接同一台路由器，并发不会有任何叠加效果——上面那条橙色横幅说的就是这种情况")
                point("✅", "不同连接走不同接口：浏览、多线程下载、云同步、视频会议等会自然分摊到两个接口")
                point("✅", "开启前会自动做 10 个连接验证；流量没分布到两个接口就自动还原，不会留下半截配置")
                point("✅", "任一口失去外网，守护进程会自动关闭并发并还原（安全阀，20 秒内）")
                point("⚠️", "单线程下载不会翻倍——一个连接始终走同一个接口")
                point("⚠️", "需要两个接口都有外网；IPv6 流量不走分流")
                point("⚠️", "VPN：自动排除 VPN 网段；若 VPN 抢占默认路由/全流量则拒绝开启")
                point("⚠️", "会启用系统 pf（当前关闭的话），并写入 /etc/pf.anchors/\(ScriptLocator.pfAnchor)——都可一键还原")
                // 原来这句写"同一网段时效果最好"，和上面那条横幅
                // （同网关 = 同一台路由器 = 没有收益）直接矛盾，用户同时看到会困惑。
                // 实际情况：同网段只是让源地址天然合法、省掉 NAT，
                // 跟带宽能不能叠完全是两件事。说清楚，别混为一谈。
                point("💡", "两个接口在同一网段时源地址天然合法，不需要额外 NAT；不同网段会自动做 NAT 修正。这只影响配置能不能跑起来，不影响带宽能否叠加")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.gapS) {
            Text(icon)
            Text(text).font(.callout)
        }
    }
}

// MARK: - 分流规则页

struct RulesView: View {
    @ObservedObject var model: NetworkModel

    var body: some View {
        Form {
            Section("已有规则（守护进程自动应用，无需密码）") {
                if model.rules.isEmpty {
                    Text("暂无规则。例：把公司内网 10.0.0.0/8 固定走有线，避免走 Wi-Fi。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.rules) { r in
                    HStack {
                        Text(r.cidr).font(.system(.body, design: .monospaced))
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(r.dev)
                        statusBadge(r.status)
                        Spacer()
                        Button(role: .destructive) { model.removeRule(cidr: r.cidr) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("删除规则")
                    }
                }
            }
            Section("添加规则") {
                HStack {
                    TextField("CIDR，如 10.0.0.0/8", text: $model.newRuleCidr)
                        .frame(width: 200)
                    TextField("接口，如 en0", text: $model.newRuleDev)
                        .frame(width: 120)
                    Button("添加") { model.addRule(cidr: model.newRuleCidr, dev: model.newRuleDev) }
                        .disabled(model.newRuleCidr.isEmpty || model.newRuleDev.isEmpty || model.busy)
                }
                if !model.ruleMessage.isEmpty {
                    Text(model.ruleMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("接口名见「状态」页（en0 以太网 / en1 Wi-Fi，扩展坞网口通常是 en4~en6）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                VStack(alignment: .leading, spacing: Theme.gapS) {
                    Text("静态分流规则：把指定网段的流量固定从某个接口出去，优先级高于默认选路。")
                        .font(.callout)
                    Text("写入 \(ScriptLocator.userRules)，普通用户可写；守护进程（root）在 ≤20 秒内添加/删除对应路由。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadRules() }
    }

    private func statusBadge(_ s: String) -> some View {
        let color: Color = s == "已生效" ? .green : (s == "等待应用" ? .orange : .secondary)
        return Text(s)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - 选路设置页

struct RoutingView: View {
    @ObservedObject var model: NetworkModel

    private let modeDescriptions: [String: String] = [
        "auto": "自动：两个接口谁有外网就走谁，以太网恢复外网后自动切回。",
        "ethernet": "强制有线：只要以太网有外网就走以太网（没有则保持现状）。",
        "wifi": "强制无线：只要 Wi-Fi 有外网就走 Wi-Fi，适合网线口是局域网/坏口的情况。",
        // 名字造成的误解必须在这里拆掉。"网速优先"听起来像"让网变快"，
        // 实际语义只是"哪个接口快就走哪个"——两条线都慢的时候它毫无办法，
        // 用户却以为买了加速器。说明白，预期才对得上。
        "speed": "网速优先：两边都能上网时，实测下载吞吐大的赢。适合网线只协商到 100M、\nWi-Fi 更快的情况。差距不到 30% 判平手，继续用当前线路。\n注意：这只是挑一条更快的线路，不会让你的宽带本身变快。",
        "latency": "延时优先：两边都能上网时，实测延迟低的赢。适合游戏/视频会议等对延迟敏感的场景。\n注意：这只是挑一条延迟更低的线路，不会降低游戏或视频服务本身的延迟。"
    ]

    var body: some View {
        Form {
            Section("选路模式") {
                Picker("模式", selection: $model.routeMode) {
                    Text("自动").tag("auto")
                    Text("网速优先").tag("speed")
                    Text("延时优先").tag("latency")
                    Text("强制以太网").tag("ethernet")
                    Text("强制 Wi-Fi").tag("wifi")
                }
                .pickerStyle(.menu)
                Text(modeDescriptions[model.routeMode] ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 把上次实测结果摆出来——用户最想看的就是"凭什么走这条"。
                // 固定/自动模式下原来什么都不显示，用户根本没法验证自己选的那个
                // 接口是不是真的更快（实测中就有人执着于 Wi-Fi，而有线快 49%）。
                Divider()
                if model.routeMode == "speed" || model.routeMode == "latency" {
                    if model.routeMode == "speed" {
                        KeyValueRow(key: "实测吞吐", value: "eth \(model.ethSpeed)   Wi-Fi \(model.wifiSpeed)")
                        Text("实测要真下载一点数据，费流量，所以每 \(model.speedRecheck) 秒才重测一次。")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        KeyValueRow(key: "实测延迟", value: "eth \(model.ethLatency)   Wi-Fi \(model.wifiLatency)")
                        Text("延迟每 \(model.latencyRecheck) 秒重测一次。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    KeyValueRow(key: "实测吞吐", value: "eth \(model.ethSpeed)   Wi-Fi \(model.wifiSpeed)")
                    KeyValueRow(key: "实测延迟", value: "eth \(model.ethLatency)   Wi-Fi \(model.wifiLatency)")
                    if model.ethSpeed == "未测" && model.wifiSpeed == "未测" {
                        Text("固定/自动模式下不会自动测量（省流量和省电），点下面的按钮测一次，\n就能看到当前选的接口是不是真的更快。")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("固定/自动模式下不会自动测量，这里是上次的结果。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                // 读取失败要单独说。以前失败时显示"未测"，跟没测过一模一样，
                // 用户不知道该重试还是该等——而这是个命令失败，重试通常就好了。
                if !model.measurementsNote.isEmpty {
                    Text(model.measurementsNote)
                        .font(.caption2).foregroundStyle(.orange)
                }
                // 说清要点密码。用户点下去突然弹出管理员密码框会很意外，
                // 甚至以为软件在要不该要的权限。
                Button(model.remeasuring ? "测量中…" : "立即重新测量（需要管理员密码）") { model.remeasureNow() }
                    .controlSize(.small)
                    .disabled(model.remeasuring)
                Text("要真下载一点数据才能测，所以走提权执行；每 \(model.speedRecheck) 秒才会自动重测一次。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("探测与通知") {
                Toggle("TLS 层探测（识别“假互联网”）", isOn: $model.routeTLS)
                Toggle("切换时弹出系统通知", isOn: $model.routeNotify)
                Toggle("以太网无外网时自动打开 Wi-Fi", isOn: $model.routeAutoWifi)
            }
            Section("判定阈值（防抖动）") {
                Stepper("连续 \(model.routeOkN) 次成功 → 判定可用", value: $model.routeOkN, in: 1...10)
                Stepper("连续 \(model.routeFailN) 次失败 → 判定不可用", value: $model.routeFailN, in: 1...10)
                Stepper("两次切换最小间隔 \(model.routeCooldown) 秒", value: $model.routeCooldown, in: 10...300, step: 5)
            }
            Section {
                HStack {
                    Button("保存并生效") { model.saveRoutingConfig() }
                    if let saved = model.routingSavedText {
                        Label(saved, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    }
                    Spacer()
                    Text("写入 \(ScriptLocator.userConf)，无需密码，≤20 秒生效")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("备份与恢复") {
                HStack(spacing: Theme.gapS) {
                    Button { model.exportConfig() } label: { Label("导出配置…", systemImage: "square.and.arrow.up") }
                    Button { model.importConfig() } label: { Label("导入配置…", systemImage: "square.and.arrow.down") }
                }
                Text("导出的是纯文本配置文件（选路模式、探测开关、阈值、分流规则），"
                     + "可以在另一台 Mac 上导入。导入后会立即保存并生效。")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.configIOError.isEmpty {
                    Label(model.configIOError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warn)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadRoutingConfig() }
    }
}

// MARK: - 体检页

struct DoctorView: View {
    @ObservedObject var model: NetworkModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            HStack(spacing: Theme.gapS) {
                LoadingButton(title: "运行体检", icon: "stethoscope",
                              loading: model.doctorRunning) { model.runDoctor() }
                Spacer()
                Button { copyResult() } label: { Label("复制", systemImage: "doc.on.doc") }
                    .disabled(model.doctorOutput.isEmpty)
                    .controlSize(.small)
                Button { exportReport() } label: { Label("导出诊断报告", systemImage: "square.and.arrow.up") }
                    .controlSize(.small)
                    .help("生成一份包含接口/路由/pf/配置/日志的完整报告，适合贴给别人排查")
            }
            Text("检查默认路由/网关/DNS/HTTPS/门户劫持/网段冲突，并给出修复建议")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(model.doctorOutput.isEmpty ? "（还没运行，点左上角「运行体检」）" : model.doctorOutput)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.gapXS)
            }
            if !model.exportMessage.isEmpty {
                Text(model.exportMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.ok)
            }
        }
        .padding(Theme.gapL)
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.doctorOutput, forType: .string)
    }

    /// 导出完整诊断报告到桌面。root 下信息更全，所以用管理员权限跑一次。
    private func exportReport() {
        model.exportMessage = "正在生成…"
        DispatchQueue.global(qos: .userInitiated).async {
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let file = desktop.appendingPathComponent("smartroute-诊断报告-\(fmt.string(from: Date())).txt")
            let cmd = "'\(ScriptLocator.scriptPath)' report"
            do {
                // 优先管理员权限（pf/launchctl 部分只有 root 能看到）；失败就退回普通权限
                var out = ""
                do { out = try Privileged.run(cmd) } catch { out = "" }
                if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let (o, _) = Shell.run(cmd, timeout: 30)
                    out = o
                }
                try out.write(to: file, atomically: true, encoding: .utf8)
                DispatchQueue.main.async {
                    model.exportMessage = "✅ 已导出到桌面：\(file.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            } catch {
                DispatchQueue.main.async {
                    model.exportMessage = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - 日志页

struct LogView: View {
    @ObservedObject var model: NetworkModel
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            HStack(spacing: Theme.gapS) {
                Toggle("自动刷新", isOn: $model.logAutoRefresh).toggleStyle(.switch)
                Button { model.loadLog() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .controlSize(.small)
                Spacer()
                Button { exportLog() } label: { Label("导出日志", systemImage: "square.and.arrow.up") }
                    .disabled(model.logText.isEmpty)
                    .controlSize(.small)
                Button("清空日志") { model.clearLog() }.disabled(model.busy)
                    .controlSize(.small)
            }
            Text(ScriptLocator.logFile).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(model.logText.isEmpty ? "（暂无日志）" : model.logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.gapXS)
            }
            if !model.exportMessage.isEmpty {
                Text(model.exportMessage).font(.caption).foregroundStyle(Theme.ok)
            }
        }
        .padding(Theme.gapL)
        .onAppear { model.loadLog() }
        .onReceive(timer) { _ in
            // 日志页 3 秒一采，同样遵守"失焦不采集"
            guard NSApp.isActive else { return }
            if model.logAutoRefresh { model.loadLog() }
        }
    }

    private func exportLog() {
        model.exportMessage = ""
        let panel = NSSavePanel()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "smartroute-log-\(fmt.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        DispatchQueue.main.async {
            presentPanel(panel) { resp in
                if resp == .OK, let url = panel.url {
                    do {
                        try model.logText.write(to: url, atomically: true, encoding: .utf8)
                        model.exportMessage = "✅ 已导出 \(url.lastPathComponent)"
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } catch {
                        model.exportMessage = "导出失败：\(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

// MARK: - 守护进程页

struct DaemonView: View {
    @ObservedObject var model: NetworkModel

    var body: some View {
        Form {
            Section("守护进程状态") {
                LabeledContent("安装状态") {
                    HStack(spacing: Theme.gapXS) {
                        Circle()
                            .fill(ScriptLocator.daemonInstalled ? Theme.ok : Theme.idle)
                            .frame(width: 8, height: 8)
                        Text(ScriptLocator.daemonInstalled ? "已安装" : "未安装")
                    }
                }
                LabeledContent("运行状态") {
                    HStack(spacing: Theme.gapXS) {
                        Circle()
                            .fill(model.snapshot.daemonState == .stopped ? Theme.bad : Theme.ok)
                            .frame(width: 8, height: 8)
                        Text(model.snapshot.daemonStateText)
                    }
                }
                LabeledContent("检测频率") { Text("每 20 秒（开机自启）") }
                if model.snapshot.daemonState == .waiting {
                    // 刚唤醒或刚装完时日志会短暂过期。说明白是在等，
                    // 别让人以为它坏了——误报的代价是有人会去重装。
                    Text("刚唤醒或刚安装，正在等待下一次检测（≤20 秒）")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                LabeledContent("当前脚本") {
                    Text(ScriptLocator.scriptPath).textSelection(.enabled).truncationMode(.middle)
                }
            }
            Section("操作") {
                Button("安装 / 重装守护进程") { model.installDaemon() }
                    .disabled(model.daemonInstalling)
                // 按钮名要和行为一致。这个按钮跑的是 `smartroute watch`，
                // 它会探测 + 滞回判定 + **当场切换默认路由**。
                // 叫"立即检测"让只想看状态的用户意外遭遇路由被改。
                Button("立即检测并切换（会改默认路由，需要管理员密码）") { runWatchOnce() }
                Text("只想看状态的话，点上面的「刷新」即可——那个是只读的，不会改任何东西。")
                    .font(.caption2).foregroundStyle(.tertiary)

                // 暂停入口。用户说"它老动我网络，我想让它停一下"时，
                // 以前唯一的选择是那颗红色"彻底卸载"——于是被逼在
                // "忍受不安"和"连根拔"之间二选一。现在有第三条路。
                Button(model.daemonPaused ? "恢复自动选路" : "暂停自动选路") {
                    model.setDaemonPaused(!model.daemonPaused)
                }
                .disabled(model.daemonInstalling)
                Text(model.daemonPaused
                     ? "已暂停：自动选路不再改你的网络。这是临时的——重启 Mac 会自动恢复；想重启也不恢复，在终端执行 sudo launchctl disable system/com.user.smartroute。"
                     : "暂停后自动选路不再改你的网络，但配置和安装都保留。这是临时的——重启 Mac 会自动恢复。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Section("登录时启动 App") {
                Toggle("开机自启 SmartRoute", isOn: .init(
                    get: { model.appAutoLaunch },
                    set: { model.setAppAutoLaunch($0) }
                ))
                Text("守护进程本身已经开机自启（负责自动选路）。这一项只是让 App 的菜单栏图标也跟着登录出现，方便随时点开看状态。")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.configIOError.isEmpty {
                    Label(model.configIOError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warn)
                }
            }
            Section {
                Text("守护进程以 root 每 20 秒检测一次：以太网没有外网时自动把默认路由切到 Wi-Fi，恢复后自动切回；"
                     + "同时应用分流规则，并在双网并发开启时监控接口健康（掉线自动还原）。安装后本 App 主要用作仪表盘和手动干预。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // MARK: 彻底卸载（零残留）
            Section {
                VStack(alignment: .leading, spacing: Theme.gapS) {
                    HStack(spacing: Theme.gapS) {
                        Image(systemName: "trash.circle.fill")
                            .foregroundStyle(Theme.bad)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: Theme.gapXS) {
                            Text("彻底卸载（程序与配置零残留）").font(.headline)
                            // 标题必须兜得住实际行为。原来写"不留任何痕迹"，
                            // 而脚本明确不删 App 偏好/窗口状态（属用户个人数据），
                            // 也不删导入前的 .conf.bak——大标题和输出自相矛盾，
                            // 用户会以为脚本漏了东西。
                            Text("程序、配置、规则、路由、进程全部清干净；你的 App 偏好与配置备份属个人数据，会保留")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: Theme.gapXS) {
                        uninstallItem("守护进程（停止 + 删 plist）")
                        uninstallItem("命令行工具 /usr/local/bin/smartroute")
                        uninstallItem("双网并发的 pf 分流规则与锚点文件")
                        uninstallItem("探测用的临时主机路由")
                        uninstallItem("全部配置文件（/etc 与 /Users/Shared）")
                        uninstallItem("状态目录、日志、/tmp 残留")
                        uninstallItem("App 本体（保留，需自己拖进废纸篓）")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Toggle(isOn: $model.uninstallKeepLogs) {
                        Text("保留日志（/var/log/smartroute.*）")
                    }
                    .font(.caption)
                    Text(model.uninstallKeepLogs
                         ? "日志会留在 /var/log 下，方便回头排查问题。"
                         : "很多人卸载正是因为用着有问题——建议保留日志，卸完好排查。")
                        .font(.caption2).foregroundStyle(.tertiary)

                    Button(role: .destructive) { model.confirmFullUninstall = true } label: {
                        Label("彻底卸载…", systemImage: "trash")
                    }
                    .disabled(model.daemonInstalling)
                    Text("卸载会还原网络服务顺序；DNS、VPN、代理都没有动过。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, Theme.gapXS)
            }

            if !model.daemonMessage.isEmpty {
                // 输出分成两段：上面一句人话结论，原文折叠进"详情"。
                // 以前把 install.sh 的终端原文（含 "sudo launchctl bootstrap ..."
                // 这种命令）直接铺给纯 App 用户看——既读不懂又被吓到，
                // 而他们真正想知道的只是"装好了吗"。
                Section("结果") {
                    Text(daemonResultSummary)
                        .font(.callout)
                        .foregroundStyle(daemonResultOK ? Theme.ok : Theme.bad)
                    DisclosureGroup("详情（原始输出）") {
                        Text(model.daemonMessage)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadAppAutoLaunch() }
        .alert("确认彻底卸载？", isPresented: $model.confirmFullUninstall) {
            Button("取消，先去导出配置", role: .cancel) {
                // 卸载不可撤销，而配置可能是用户调了很久的。
                // 原来只在文案里说"建议先导出配置"，没有按钮——
                // 用户得自己去找导出入口，多数人就跳过这步然后后悔。
                model.exportConfig()
            }
            Button("彻底卸载", role: .destructive) {
                model.uninstallDaemon(keepLogs: model.uninstallKeepLogs)
            }
        } message: {
            // 文案必须和 uninstall.sh 的实际行为一致。以前这里写"以及
            // /Applications/SmartRoute.app"，而命令实际带 --keep-app
            // （正在运行的 App 删不掉自己）——用户点完看到输出里"保留 App"，
            // "说好的全删呢？"卸载是信任最脆弱的时刻，这种对不上的承诺伤害尤其大。
            // 网络那句也要改：服务顺序会被改，但卸载时会按备份还原。
            // 拆成多行字符串字面量。原来几段用 + 连，编译器要反复推断拼接
            // 结果的类型，直接"无法在合理时间内完成类型检查"而构建失败。
            Text("""
                 将停止并删除守护进程、命令行工具、pf 分流规则、全部配置与日志，并还原网络服务顺序。

                 App 本体将保留（正在运行，删不掉自己）——卸完请自己拖进废纸篓。

                 已保存的 Wi-Fi 不会被删除。

                 这个操作不可撤销，建议先导出配置。
                 """)
        }
    }

    /// 把 install.sh / uninstall.sh 的终端原文归纳成一句人话。
    /// 纯 App 用户不需要看懂 launchctl，只需要知道"成没成"。
    private var daemonResultSummary: String {
        let msg = model.daemonMessage
        if msg.contains("已取消授权") { return "已取消，什么都没有改动。" }
        if msg.contains("守护进程没起来") || msg.contains("安装失败") {
            return "安装失败：自动选路没有生效。展开「详情」看原因，照里面的命令手动做一遍即可。"
        }
        // 残差必须排在"卸载完成"前面。uninstall.sh 有残留时，输出里
        // "还有 N 项残留（见上）"和标题行会同时存在；而 App 流程下
        // --keep-app 让 /Applications/SmartRoute.app 必然计成残留
        // （NetworkModel.swift 硬编码 --keep-app，uninstall.sh 对它只 warn 不 rm），
        // 所以这根本不是边缘情况——顺序一反，每次卸载都会被报成"都已清干净"。
        if msg.contains("项残留") {
            return "卸载未完全清干净：还有残留项。展开「详情」，照里面每条的手动命令逐条删。"
        }
        if msg.contains("卸载完成") { return "卸载完成。程序、配置、规则、路由、进程都已清干净。" }
        if msg.contains("已暂停") { return "已暂停自动选路。重启 Mac 会恢复；想重启也不恢复，用 launchctl disable。" }
        if msg.contains("已恢复自动选路") { return "已恢复自动选路，每 20 秒检测一次。" }
        if msg.contains("已通过 bootstrap") || msg.contains("守护进程已加载并运行") {
            return "守护进程已装好并在运行，每 20 秒自动检测一次。"
        }
        if msg.contains("失败") { return "操作失败，展开「详情」看原因。" }
        return "操作完成。"
    }

    private var daemonResultOK: Bool {
        let msg = model.daemonMessage
        if msg.contains("已取消授权") { return true }
        // 残差也要转红。原来只排除"失败"，而"还有 N 项残留"不含"失败"二字，
        // 于是未卸干净和全部清干净一样是绿的——三态被二值成了"成功"。
        if msg.contains("项残留") { return false }
        return !msg.contains("失败") && !msg.contains("守护进程没起来")
    }

    private func uninstallItem(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.gapXS) {
            Image(systemName: "minus.circle.fill")
                .font(.caption2)
                .foregroundStyle(Theme.bad.opacity(0.7))
            Text(text)
        }
    }

    private func runWatchOnce() {
        model.watchRunning = true
        model.runWatch { ok, out in
            model.watchRunning = false
            model.watchResult = (ok ? "" : "失败: ") + out
            model.refresh()
        }
    }
}

// MARK: - 关于页

struct AboutView: View {
    @ObservedObject var model: NetworkModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: Theme.gapM) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: Theme.gapXS) {
                        Text("SmartRoute").font(.title2.bold())
                        Text("macOS 智能选路 · 双网并发 · 分流规则").foregroundStyle(.secondary)
                        Text("版本 2.2").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            // 「安全吗」在 App 内原来没有总览，答案散落在安装文档里。
            // 用户装了 root 级守护进程，理应在 App 内一眼看清
            // 它要什么权限、会改哪些系统位置、不碰什么。文案 INSTALL.md 早有，
            // 搬进来即可——放在"工作方式"前面，因为这是更靠前的疑问。
            Section("权限与隐私") {
                Text("需要管理员密码的操作")
                    .font(.caption).foregroundStyle(.secondary)
                Text("• 安装 / 更新 / 卸载守护进程、暂停或恢复自动选路")
                Text("• 修改网络服务顺序与默认路由、启用系统 pf 写分流规则")
                Text("• 手动检测、手动测速（读取状态不需要密码）")
                Text("不会碰的东西")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, Theme.gapXS)
                Text("• DNS、VPN、系统代理、hosts 一律不动")
                Text("• 导出的报告不含密码、令牌或任何凭据")
                Text("• 不在后台联网回传任何数据")
            }
            Section("工作方式") {
                Text("• 每 20 秒探测以太网和 Wi-Fi 的外网连通性（ping → TCP → TLS 三层）")
                Text("• 没有外网的接口不会提供默认路由；恢复后自动切回（带滞回与冷却）")
                Text("• 双网并发通过 pf 轮询把不同连接分发到两个网关（需两个接口都有外网）")
                Text("• 分流规则把指定网段固定从指定接口出去（静态路由）")
            }
            Section("文件位置") {
                fileRow("主脚本", ScriptLocator.scriptPath)
                fileRow("日志", ScriptLocator.logFile)
                fileRow("状态", ScriptLocator.stateFile)
                fileRow("用户配置", ScriptLocator.userConf)
                fileRow("分流规则", ScriptLocator.userRules)
            }
            Section {
                Text("命令行可用：smartroute status / test / doctor / balance / rule / stats / quality")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func fileRow(_ name: String, _ path: String) -> some View {
        HStack {
            Text(name).frame(width: 70, alignment: .leading)
            Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
    }
}

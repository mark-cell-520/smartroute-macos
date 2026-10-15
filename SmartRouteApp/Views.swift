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
            List(selection: $model.page) {
                Section("监控") {
                    ForEach([AppPage.status, .speed, .balance, .rules]) { p in
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
            model.startSpeedMonitor()
        }
        .onReceive(timer) { _ in
            // 失焦时完全不采集：5 秒一次、每次五六个进程，后台白烧电。
            // 切回前台时 applicationDidBecomeActive 会立刻补一次刷新，数据不会旧。
            guard NSApp.isActive else { return }
            model.refresh()
            if model.page == .balance { model.loadBalance() }
            if model.page == .rules { model.loadRules() }
        }
        .onReceive(qualityTimer) { _ in
            guard NSApp.isActive else { return }
            if model.page == .speed { model.loadQuality() }
        }
    }
}

// MARK: - 状态页

struct StatusView: View {
    @ObservedObject var model: NetworkModel

    private var ethInterface: InterfaceInfo? { model.snapshot.interfaces.first { $0.role == "以太网" } }
    private var wifiInterface: InterfaceInfo? { model.snapshot.interfaces.first { $0.role == "Wi-Fi" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapM) {
                if !ScriptLocator.daemonInstalled {
                    daemonBanner
                } else if model.snapshot.daemonScriptOutdated {
                    daemonOutdatedBanner
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

    private var daemonBanner: some View {
        Banner(icon: "exclamationmark.triangle.fill", color: Theme.warn,
               title: "守护进程尚未安装",
               message: "安装后每 20 秒自动检测：以太网没有外网时自动切到 Wi-Fi，恢复后自动切回（开机自启）",
               buttonTitle: model.daemonInstalling ? nil : "安装守护进程") {
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
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前默认路由").font(.headline)
                    Text("\(deviceDisplayName(model.snapshot.defaultDevice))   via   \(model.snapshot.defaultGateway.isEmpty ? "?" : model.snapshot.defaultGateway)")
                        .font(.title3.monospaced())
                    HStack(spacing: Theme.gapXS) {
                        Pill(text: model.snapshot.defaultReachable ? "网关可达" : "网关不可达",
                             color: model.snapshot.defaultReachable ? Theme.ok : Theme.warn)
                        Text("更新于 \(model.snapshot.lastUpdated)")
                            .font(.caption).foregroundStyle(.secondary)
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
                            }
                            Text(svc.device).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func deviceDisplayName(_ device: String) -> String {
        guard !device.isEmpty else { return "无" }
        if let iface = model.snapshot.interfaces.first(where: { $0.device == device }) {
            return "\(iface.role)（\(device)）"
        }
        if device.hasPrefix("utun") || device.hasPrefix("ppp") || device.hasPrefix("ipsec") {
            return "\(device)（VPN/拨号）"
        }
        return device
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
                }
                if let iface, iface.active {
                    KeyValueRow(key: "设备", value: iface.device, monospaced: true)
                    KeyValueRow(key: "IP", value: iface.ip, monospaced: true)
                    KeyValueRow(key: "网关", value: iface.gateway, monospaced: true)
                    KeyValueRow(key: "服务", value: iface.service)
                    KeyValueRow(key: "连续探测", value: "\(streak) 次")
                } else {
                    EmptyState(icon: "cable.connector.slash",
                               title: "未连接",
                               message: "插上线后会自动出现在这里")
                }
            }
        }
    }
}

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
            VStack(alignment: .leading, spacing: 16) {
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
                hintCard
            }
            .padding()
        }
        .onAppear { model.loadQuality() }
    }

    private var qualityCard: some View {
        Card(title: "延迟与丢包", subtitle: "每 30 秒更新；root 下按接口分别探测") {
            VStack(alignment: .leading, spacing: 10) {
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
            .padding(6)
        }
    }

    private func qualityValue(label: String, value: String, color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).foregroundStyle(color)
        }
        .frame(minWidth: 56)
    }

    private var hintCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label("想两个接口同时跑流量？去「双网并发」页开启 pf 分流。", systemImage: "arrow.triangle.branch")
                    .font(.callout)
                Text("开启后这里能直接看到两个接口的实时曲线同时起伏，即证明流量被分摊。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
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
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).font(.title3)
                    Text("\(role)（\(dev)）").font(.headline)
                    Spacer()
                    HStack(spacing: 14) {
                        Label(formatSpeed(model.speedIn[dev] ?? 0), systemImage: "arrow.down")
                            .foregroundStyle(.green)
                            .font(.system(.callout, design: .monospaced))
                        Label(formatSpeed(model.speedOut[dev] ?? 0), systemImage: "arrow.up")
                            .foregroundStyle(.blue)
                            .font(.system(.callout, design: .monospaced))
                    }
                }
                HStack(spacing: 8) {
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
            .padding(6)
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
                Path { p in
                    guard values.count > 1 else { return }
                    let maxV = max(values.max() ?? 1, 1.0)
                    let w = geo.size.width, h = geo.size.height
                    for (i, v) in values.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(values.count - 1)
                        let y = h - max(1, h * CGFloat(v / maxV))
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - 双网并发页

struct BalanceView: View {
    @ObservedObject var model: NetworkModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    statusDot(on: model.balanceOn, text: model.balanceOn ? "已开启" : "未开启")
                    Spacer()
                    if model.balanceLoading { ProgressView().controlSize(.small) }
                }
                LabeledContent("配置开关", value: "BALANCE=\(model.balanceOn ? 1 : 0)")
                LabeledContent("分流策略", value: model.balanceMode == "fastest" ? "最快线路" : "轮询两条")
                LabeledContent("系统 pf", value: pfLine)
                LabeledContent("分流规则", value: ruleLine)
            }
            .padding(6)
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
        HStack(spacing: 6) {
            Circle().fill(on ? Theme.ok : Theme.idle).frame(width: 10, height: 10)
            Text(text).font(.headline)
        }
    }

    private var controlCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.balanceOn
                     ? (model.balanceMode == "fastest" ? "正在把新连接全部送到延迟更低的那条线路。" : "正在把新连接轮询分发到两个接口。")
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
                    HStack(spacing: 16) {
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
                        Text(model.balanceMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if model.balanceOn {
                    Text(model.balanceMode == "fastest"
                         ? "守护进程会定期重测两边延迟，某条线路变慢就自动改走另一条。"
                         : "撤销会清空分流规则；如果 pf 是由本工具开启的，撤销时也会把系统 pf 关回去。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("轮询：多连接/多下载分摊到两个接口，带宽可叠加。\n最快：所有新连接走延迟低的那条，适合一条稳一条快的场景。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private var liveCard: some View {
        Card(title: model.balanceMode == "fastest"
             ? "实时流量（只有一条在动 = 正在走最快线路）"
                 : "实时流量（两个接口一起动 = 分流生效）") {
            VStack(alignment: .leading, spacing: 8) {
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
            }
            .padding(6)
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
            VStack(alignment: .leading, spacing: 8) {
                point("✅", "不同连接走不同接口：浏览、多线程下载、云同步、视频会议等会自然分摊到两个接口")
                point("✅", "开启前会自动做 10 个连接验证；流量没分布到两个接口就自动还原，不会留下半截配置")
                point("✅", "任一口失去外网，守护进程会自动关闭并发并还原（安全阀，20 秒内）")
                point("⚠️", "单线程下载不会翻倍——一个连接始终走同一个接口")
                point("⚠️", "需要两个接口都有外网；IPv6 流量不走分流")
                point("⚠️", "VPN：自动排除 VPN 网段；若 VPN 抢占默认路由/全流量则拒绝开启")
                point("⚠️", "会启用系统 pf（当前关闭的话），并写入 /etc/pf.anchors/\(ScriptLocator.pfAnchor)——都可一键还原")
                point("💡", "两个接口在同一网段时效果最好（源地址天然合法）；不同网段会额外做 NAT")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
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
                VStack(alignment: .leading, spacing: 6) {
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
        "wifi": "强制无线：只要 Wi-Fi 有外网就走 Wi-Fi，适合网线口是局域网/坏口的情况。"
    ]

    var body: some View {
        Form {
            Section("选路模式") {
                Picker("模式", selection: $model.routeMode) {
                    Text("自动").tag("auto")
                    Text("强制以太网").tag("ethernet")
                    Text("强制 Wi-Fi").tag("wifi")
                }
                .pickerStyle(.segmented)
                Text(modeDescriptions[model.routeMode] ?? "").font(.caption).foregroundStyle(.secondary)
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
                        Label(saved, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Spacer()
                    Text("写入 \(ScriptLocator.userConf)，无需密码，≤20 秒生效")
                        .font(.caption).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("运行体检") { model.runDoctor() }.disabled(model.doctorRunning)
                if model.doctorRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("复制结果") { copyResult() }.disabled(model.doctorOutput.isEmpty)
            }
            Text("检查默认路由/网关/DNS/HTTPS/门户劫持/网段冲突，并给出修复建议")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(model.doctorOutput)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
        }
        .padding()
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.doctorOutput, forType: .string)
    }
}

// MARK: - 日志页

struct LogView: View {
    @ObservedObject var model: NetworkModel
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("自动刷新", isOn: $model.logAutoRefresh).toggleStyle(.switch)
                Button("刷新") { model.loadLog() }
                Spacer()
                Button("清空日志") { model.clearLog() }.disabled(model.busy)
            }
            Text(ScriptLocator.logFile).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(model.logText.isEmpty ? "（暂无日志）" : model.logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
        }
        .padding()
        .onAppear { model.loadLog() }
        .onReceive(timer) { _ in if model.logAutoRefresh { model.loadLog() } }
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
                            .fill(model.snapshot.daemonRunning ? Theme.ok : Theme.idle)
                            .frame(width: 8, height: 8)
                        Text(model.snapshot.daemonRunning ? "运行中" : "未在运行")
                    }
                }
                LabeledContent("检测频率") { Text("每 20 秒（开机自启）") }
                LabeledContent("当前脚本") {
                    Text(ScriptLocator.scriptPath).textSelection(.enabled).truncationMode(.middle)
                }
            }
            Section("操作") {
                Button("安装 / 重装守护进程") { model.installDaemon() }
                    .disabled(model.daemonInstalling)
                Button("立即运行一次检测（需要管理员密码）") { runWatchOnce() }
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text("彻底卸载（零残留）").font(.headline)
                            Text("会一次清掉下面全部内容，卸载完不留任何痕迹")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        uninstallItem("守护进程（停止 + 删 plist）")
                        uninstallItem("命令行工具 /usr/local/bin/smartroute")
                        uninstallItem("双网并发的 pf 分流规则与锚点文件")
                        uninstallItem("探测用的临时主机路由")
                        uninstallItem("全部配置文件（/etc 与 /Users/Shared）")
                        uninstallItem("状态目录、日志、/tmp 残留")
                        uninstallItem("App 本体 /Applications/SmartRoute.app")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button(role: .destructive) { model.confirmFullUninstall = true } label: {
                        Label("彻底卸载…", systemImage: "trash")
                    }
                    .disabled(model.daemonInstalling)
                    Text("卸载后网络设置保持原样，不会动你现有的路由。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, Theme.gapXS)
            }

            if !model.daemonMessage.isEmpty {
                Section("输出") {
                    Text(model.daemonMessage)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .alert("确认彻底卸载？", isPresented: $model.confirmFullUninstall) {
            Button("取消", role: .cancel) {}
            Button("彻底卸载", role: .destructive) {
                model.uninstallDaemon()
            }
        } message: {
            Text("将停止并删除守护进程、命令行工具、pf 分流规则、全部配置与日志，以及 /Applications/SmartRoute.app。\n\n"
                 + "这个操作不可撤销，建议先导出配置。")
        }
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
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SmartRoute").font(.title2.bold())
                        Text("macOS 智能选路 · 双网并发 · 分流规则").foregroundStyle(.secondary)
                        Text("版本 2.1").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
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

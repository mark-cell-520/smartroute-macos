import Foundation
import SwiftUI

// MARK: - 页面枚举

enum AppPage: String, CaseIterable, Identifiable {
    case status, speed, balance, wifi, rules, routing, doctor, log, daemon, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .status:  return "状态"
        case .speed:   return "网速与延迟"
        case .balance: return "双网并发"
        case .wifi:    return "Wi-Fi 网络"
        case .rules:   return "分流规则"
        case .routing: return "选路设置"
        case .doctor:  return "体检"
        case .log:     return "日志"
        case .daemon:  return "守护进程"
        case .about:   return "关于"
        }
    }
    /// 副标题：显示在 detail 栏顶部，说明这一页是干什么的
    var subtitle: String {
        switch self {
        case .status:  return "谁在上网、网关通不通、服务顺序一览"
        case .speed:   return "实时速率与延迟；失焦时自动停采"
        case .balance: return "按连接把流量分摊到两条线路（实验特性）"
        case .wifi:    return "选网络、看信号；上不了网时自动换能上网的"
        case .rules:   return "指定网段固定走某条线路"
        case .routing: return "选路模式与探测参数"
        case .doctor:  return "一键排查守护进程、路由与 pf"
        case .log:     return "守护进程的判定记录"
        case .daemon: return "安装 / 更新 / 卸载自动选路服务"
        case .about:   return "版本、作者与致谢"
        }
    }
    var icon: String {
        switch self {
        case .status:  return "dot.radiowaves.left.and.right"
        case .speed:   return "speedometer"
        case .balance: return "arrow.triangle.branch"
        case .wifi:    return "wifi"
        case .rules:   return "list.bullet.rectangle"
        case .routing: return "slider.horizontal.3"
        case .doctor:  return "stethoscope"
        case .log:     return "text.alignleft"
        case .daemon:  return "gear"
        case .about:   return "info.circle"
        }
    }
}

// MARK: - 数据结构

struct InterfaceInfo: Identifiable, Equatable {
    let id = UUID()
    var role: String        // "以太网" / "Wi-Fi"
    var device: String
    var service: String
    var ip: String
    var gateway: String
    var active: Bool
}

struct ServiceEntry: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var device: String
    var enabled: Bool
}

struct QualityInfo: Equatable {
    var dev = ""
    var via = ""
    var loss = "?"
    var min = "?"
    var avg = "?"
    var max = "?"
}

struct RouteRule: Identifiable, Equatable {
    var id: String { "\(cidr)->\(dev)" }
    var cidr: String
    var dev: String
    var status: String
}

struct NetworkSnapshot {
    var interfaces: [InterfaceInfo] = []
    var services: [ServiceEntry] = []
    var defaultDevice: String = ""
    var defaultGateway: String = ""
    var defaultReachable: Bool = false
    /// 网关状态是否"未知"（禁 ping / VPN 虚拟网关 / 同网段直连）。
    /// 为 true 时界面不能说"不可达"——那会用红字吓一个正在正常上网的用户。
    var gatewayUnknown: Bool = false
    var ethOK: String = "-"
    var wifiOK: String = "-"
    var streakEth: String = "-"
    var streakWifi: String = "-"
    var lastSwitch: String = "从未"
    var switchCount: String = "0"
    var mode: String = "auto"
    var daemonState: DaemonState = .stopped
    var daemonScriptOutdated: Bool = false
    var lastUpdated: String = ""
    /// 上次成功采集的时间（用于算"x 秒前"，比字符串更准）
    var lastUpdatedAt: Date = Date.distantPast
}

final class NetworkModel: ObservableObject {

    /// 供菜单栏（AppDelegate）复用同一个实例
    static weak var shared: NetworkModel?

    // MARK: 基础状态
    /// 双网并发状态是否"未知"（读取失败）。为 true 时界面要显示"状态未知，
    /// 点击重试"，不能拿上次的值冒充当前值，更不能猜"未开启"——
    /// 猜错会让用户去点"开启"，实际把正在跑的 pf 规则关掉。
    @Published var balanceUnknown: Bool = false
    /// 上一次安装/更新守护进程是否失败。用于把横幅从"装好了"翻成"没装上"——
    /// 以前横幅只看 plist 文件在不在，而 plist 在校验之前就 cp 进去了，
    /// 于是安装失败时横幅照样消失，用户在状态页看到的是完全正常的假象。
    @Published var installFailed: Bool = false
    /// 卸载时是否保留日志。默认 true：卸载的常见原因是"用着有问题"，
    /// 卸完想排查时日志却被卸载流程自己吃了，唯一的证据就没了。
    @Published var uninstallKeepLogs: Bool = true
    /// 用户是否主动暂停了自动选路。暂停不是卸载：守护进程 plist 还在，
    /// 重启 Mac 会自动恢复运行。要"重启也不恢复"得用 launchctl disable。
    @Published var daemonPaused = false
    /// 守护进程是否确实在跑。注意"未在运行"的判定只认 .stopped——
    /// .waiting（刚唤醒/刚装完）不下结论，避免误报让人去重装。
    var daemonRunning: Bool { snapshot.daemonState == .running }
    @Published var snapshot = NetworkSnapshot()
    @Published var busy: Bool = false
    @Published var message: String = ""
    @Published var page: AppPage = .status

    // MARK: 各页面状态（集中在 class 中，避免 SwiftUI 结构体 self 不可变问题）
    @Published var watchResult: String?
    @Published var watchRunning = false
    @Published var routingSavedText: String?
    @Published var doctorOutput = "点击“运行体检”开始检查…"
    @Published var doctorRunning = false
    @Published var logText = ""
    @Published var daemonMessage = ""
    /// 彻底卸载的二次确认弹窗（此环境 @State 宏不可用，只能放 Model 里）
    @Published var confirmFullUninstall = false
    /// 体检页"导出诊断报告"的结果提示
    @Published var exportMessage = ""
    /// 选路页配置导入/导出的错误或结果提示
    @Published var configIOError = ""
    /// App 是否开机自启（登录时把菜单栏图标带出来）
    @Published var appAutoLaunch = false

    // MARK: - 自适应轮询
    /// 连续多少次快照"关键字段"完全没变（用于降频省电）
    private var stableStreak = 0
    private var lastPollAt = Date.distantPast
    /// 当前生效的轮询间隔：默认 5 秒；连续 36 秒（约 6 次）没变化就拉到 10 秒
    private(set) var pollInterval: TimeInterval = 5
    private var lastSignature = ""

    /// 到了该采集的时候吗？（配合 5 秒的 Timer 实现自适应间隔）
    func shouldPoll() -> Bool {
        Date().timeIntervalSince(lastPollAt) >= pollInterval
    }

    /// 记录本次轮询时间，并按快照变化情况调整下一次间隔
    private func notePoll(signature: String) {
        lastPollAt = Date()
        if signature == lastSignature {
            stableStreak += 1
        } else {
            stableStreak = 0
            lastSignature = signature
        }
        // 稳定 6 次（约 30~60 秒）后降频到 10 秒；一有变化立刻回到 5 秒
        pollInterval = stableStreak >= 6 ? 10 : 5
    }

    /// 快照里"值得为它多跑一次命令"的字段签名
    private func signature(of snap: NetworkSnapshot) -> String {
        var ips = ""
        for i in snap.interfaces.sorted(by: { $0.device < $1.device }) {
            ips += "\(i.device):\(i.ip):\(i.active ? 1 : 0);"
        }
        return [snap.defaultDevice, snap.defaultGateway,
                snap.defaultReachable ? "1" : "0",
                snap.ethOK, snap.wifiOK, snap.mode, ips].joined(separator: "|")
    }
    @Published var daemonInstalling = false

    // MARK: 选路表单
    @Published var routeMode = "auto"
    @Published var routeNotify = false
    @Published var routeAutoWifi = false
    @Published var routeTLS = true
    @Published var routeOkN = 2
    @Published var routeFailN = 3
    @Published var routeCooldown = 45
    // 网速/延时优先模式下展示的实测结果
    @Published var ethSpeed = "未测"
    @Published var wifiSpeed = "未测"
    @Published var ethLatency = "未测"
    @Published var wifiLatency = "未测"
    @Published var speedRecheck = 300
    @Published var latencyRecheck = 60
    @Published var remeasuring = false

    // MARK: 日志页
    @Published var logAutoRefresh = true

    // MARK: 网速
    @Published var monitoredDevices: [String] = []
    @Published var speedIn: [String: Double] = [:]
    @Published var speedOut: [String: Double] = [:]
    @Published var historyIn: [String: [Double]] = [:]
    @Published var historyOut: [String: [Double]] = [:]
    private var lastBytes: [String: (inB: UInt64, outB: UInt64, at: Date)] = [:]
    private var speedTimer: DispatchSourceTimer?

    // MARK: 延迟/丢包
    @Published var quality: [String: QualityInfo] = [:]

    // MARK: 双网并发
    @Published var balanceStatusText = "（读取中…）"
    @Published var balanceOn = false
    @Published var balanceMode = "round-robin"   // round-robin | fastest
    /// 两个接口网关相同（同一台路由器）——不是两条 WAN，分流没有带宽收益。
    /// 从 balance status 的警告行解析出来，让 App 在用户最常看的地方提示。
    @Published var balanceSameGateway = ""
    /// measurements 读取失败时的说明（空=正常）。区别于"未测"——
    /// 未测是"还没测过"，这个是"命令失败了"。
    @Published var measurementsNote = ""
    @Published var pendingBalanceMode = "round-robin"   // 用户在下拉里选的、尚未生效的策略
    @Published var balanceLatency: [String: String] = [:]   // 设备名 -> "14.3 ms"
    @Published var balanceLoading = false
    @Published var balanceMessage = ""

    // MARK: Wi-Fi
    @Published var wifiSaved: [String] = []          // 已保存的网络（靠前优先）
    @Published var wifiSignal = ""                   // "-70 dBm"
    @Published var wifiChannel = ""                  // "44"
    @Published var wifiBars = 0                      // 0~4
    @Published var wifiRate = ""                     // 协商速率 Mbps（真实值，非标称）
    @Published var wifiNoise = ""                    // 噪声底 dBm
    // 附近扫描：哪些已保存网络够得着、信号多强。
    // 有了它才能把候选按信号排序、把够不着的置灰——都不需要定位权限，
    // 也不用打断当前连接（按指定 SSID 扫描即可）。
    @Published var wifiNearby: [WifiParsing.Nearby] = []
    @Published var wifiScanning = false
    @Published var wifiScanNote = ""                  // "有 N 个未能确认" 之类
    @Published var wifiScanAt: Date? = nil            // 上次扫描时间
    @Published var wifiLoading = false
    @Published var wifiMessage = ""
    /// wifiMessage 是成功还是失败。以前靠字符串匹配 "失败"/"❌" 上色，
    /// 于是"网络名里含空格，无法加入优先列表"这种**警告**被染成成功绿——
    /// 用户以为存进去了，其实没有。severity 由设置消息的人显式给出。
    @Published var wifiMessageFailed = false
    @Published var wifiJoining = ""                  // 正在连接的 SSID（用于转圈）
    @Published var wifiFailoverOn = false
    @Published var wifiPreferred = ""                // 逗号分隔的优先列表

    // MARK: 分流规则
    @Published var rules: [RouteRule] = []
    @Published var ruleMessage = ""
    @Published var newRuleCidr = ""
    @Published var newRuleDev = ""

    // MARK: - 防重入守卫

    /// 定时器/页面切换会反复触发采集，慢命令（balance status 4.7s、quality 最长 30s、
    /// stats 每秒一次）一旦上次没跑完又触发一次，进程就会越积越多，界面越来越卡。
    /// 用这个 Set 保证"同名操作同时只跑一个"，跑得慢就跳过本次，下次定时再来。
    private let inFlightLock = NSLock()
    private var inFlight = Set<String>()

    private func beginOp(_ name: String) -> Bool {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        if inFlight.contains(name) { return false }
        inFlight.insert(name)
        return true
    }
    private func endOp(_ name: String) {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        inFlight.remove(name)
    }

    // MARK: - 采集

    /// 采集一次网络快照。
    ///
    /// 必须在后台线程跑：内部要串行执行十来个 shell 命令
    /// （networksetup ×2、route、ifconfig ×N、networksetup -getinfo ×N、pgrep、ping），
    /// 在主线程上跑会阻塞 UI 一两秒，表现为"界面卡住不动"。
    /// 多个调用会合并成一次（onAppear / 切页面 / 点刷新 经常连着来）。
    func refresh() {
        guard beginOp("refresh") else { return }   // 已有一次在跑就跳过，避免堆积
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let snap = self.collectSnapshot()
            DispatchQueue.main.async {
                self.snapshot = snap
                self.notePoll(signature: self.signature(of: snap))
                self.endOp("refresh")
            }
        }
    }

    /// 实际采集逻辑（只在后台线程调用），返回完整快照
    private func collectSnapshot() -> NetworkSnapshot {
        var snapshot = NetworkSnapshot()
        let hw = parseHardwarePorts(Shell.run("networksetup -listallhardwareports", timeout: 5).out)
        let services = parseServiceOrder(Shell.run("networksetup -listnetworkserviceorder", timeout: 5).out)

        var serviceByDevice: [String: ServiceEntry] = [:]
        for s in services { serviceByDevice[s.device] = s }

        let routeOut = Shell.run("route -n get default", timeout: 5).out
        var defDev = "", defGw = ""
        for line in routeOut.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                defGw = String(t.dropFirst("gateway:".count)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("interface:") {
                defDev = String(t.dropFirst("interface:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        // 网关"不可达"的红字以前只 ping 一次（800ms），于是三类完全正常的情况
        // 都会被判成不可达：走 VPN 时默认网关是 utun 的虚拟地址、网络禁 ICMP、
        // 以及 route 报 "gateway: link"（同网段直连，没有可 ping 的网关 IP）。
        // 用户明明上着网，却被一个红字吓到。
        // 修：ping 不通时用 TCP 兜一次——本项目自己就有 TCP/TLS 三层探测，
        // 没理由在这里只信 ICMP。
        var gwReachable = false
        var gwUnknown = false
        if !defGw.isEmpty {
            if defGw == "link" {
                // 同网段直连，没有网关 IP 可 ping。这不是故障，是"没有这项信息"。
                gwUnknown = true
            } else {
                let (_, code) = Shell.run("ping -c 1 -W 800 \(defGw)", timeout: 3)
                if code == 0 {
                    gwReachable = true
                } else {
                    // ICMP 不通 ≠ 不通。禁 ping 的路由器、VPN 的 utun 虚拟网关
                    // 都很常见。用 TCP 连网关的 80/443 复核一次再下结论。
                    let (_, tcp) = Shell.run(
                        "nc -z -G 1 \(defGw) 80 2>/dev/null || nc -z -G 1 \(defGw) 443 2>/dev/null",
                        timeout: 4)
                    if tcp == 0 {
                        gwReachable = true
                    } else {
                        // TCP 也不通：可能是真断了，也可能只是这个网关不响应
                        // 这两种探测（比如纯二层设备）。标成"未知"而不是"不可达"，
                        // 让界面说"探测不到"，别用红字吓人。
                        gwUnknown = true
                    }
                }
            }
        } else {
            gwUnknown = true
        }
        snapshot.gatewayUnknown = gwUnknown

        // 一次性拿所有接口的 IP 和网关：比"每个接口各跑一次 ifconfig /
        // networksetup -getinfo"少 2N-2 个进程。一次采集从十多个进程降到 5 个。
        let ips = allIPAddresses()
        let gateways = allGateways()

        var interfaces: [InterfaceInfo] = []
        for entry in hw {
            let r = role(of: entry.port)
            if r == "其他" { continue }
            let ip = ips[entry.device] ?? ""
            let svc = serviceByDevice[entry.device]
            let gw = gateways[entry.device] ?? router(of: svc?.name ?? "")
            interfaces.append(InterfaceInfo(role: r,
                                            device: entry.device,
                                            service: svc?.name ?? "-",
                                            ip: ip.isEmpty ? "-" : ip,
                                            gateway: gw.isEmpty ? "-" : gw,
                                            active: !ip.isEmpty))
        }
        interfaces.sort { a, b in
            if a.role == b.role { return a.device < b.device }
            return a.role == "以太网"
        }

        let state = readKeyValues(ScriptLocator.stateFile)

        snapshot.interfaces = interfaces
        snapshot.services = services
        snapshot.defaultDevice = defDev
        snapshot.defaultGateway = defGw
        snapshot.defaultReachable = gwReachable
        snapshot.ethOK = state["eth_ok"] ?? "-"
        snapshot.wifiOK = state["wifi_ok"] ?? "-"
        snapshot.streakEth = state["streak_eth"] ?? "-"
        snapshot.streakWifi = state["streak_wifi"] ?? "-"
        snapshot.switchCount = state["switch_count"] ?? "0"
        snapshot.lastSwitch = humanize(state["last_switch"] ?? "")
        snapshot.mode = readMode()
        snapshot.daemonState = daemonState()
        snapshot.daemonScriptOutdated = ScriptLocator.daemonScriptOutdated
        snapshot.lastUpdated = Self.timeString()
        snapshot.lastUpdatedAt = Date()
        return snapshot
    }

    // MARK: - 配置

    func loadConfig() -> [String: String] {
        var result: [String: String] = [
            "MODE": "auto", "OK_N": "2", "FAIL_N": "3", "COOLDOWN": "45",
            "TLS_PROBE": "1", "NOTIFY": "0", "AUTO_WIFI_POWER": "0", "BALANCE": "0",
            "PING_TIMEOUT": "800", "NC_TIMEOUT": "2"
        ]
        for path in [ScriptLocator.systemConf, ScriptLocator.userConf] {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
                let key = String(t[t.startIndex..<eq])
                let value = String(t[t.index(after: eq)...])
                if !key.isEmpty { result[key] = value }
            }
        }
        return result
    }

    func setConfigBatch(_ items: [(String, String)], completion: @escaping (Bool, String) -> Void) {
        let script = ScriptLocator.configScriptPath
        DispatchQueue.global().async {
            var failures: [String] = []
            for (key, value) in items {
                let (out, code) = Shell.run("'\(script)' set \(key)=\(value)", timeout: 10)
                if code != 0 { failures.append("\(key): \(out)") }
            }
            // 普通权限写不进去（多半是用户级配置被 root 创建过，/Users/Shared 带 sticky 位），
            // 用管理员权限重试一次——会弹系统密码框，成功后属主也会被修好
            if !failures.isEmpty {
                do {
                    for (key, value) in items {
                        _ = try Privileged.run("'\(script)' set \(key)=\(value)")
                    }
                    DispatchQueue.main.async { completion(true, "已用管理员权限保存") }
                    return
                } catch {
                    DispatchQueue.main.async {
                        var msg = failures.joined(separator: "; ")
                        if msg.contains("root") || msg.contains("无法写入") {
                            msg += "\n\n提示：用户配置被 root 占用过。已在 App 内用管理员权限重试仍未成功，可在终端执行：\nsudo smartroute fixconf"
                        }
                        completion(false, msg)
                    }
                    return
                }
            }
            DispatchQueue.main.async {
                completion(failures.isEmpty, failures.joined(separator: "; "))
            }
        }
    }

    // MARK: - 选路表单

    // MARK: - App 开机自启
    // 用一个 ~/Library/LaunchAgents 里的 plist 实现：比 SMAppService 少受签名/位置限制，
    // 用户在访达里把 App 挪了位置也能靠 path 判断。

    private var launchAgentPlist: String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.user.smartroute.app.plist"
    }

    private var appPath: String {
        // 优先 /Applications 里的安装副本；开发构建时用当前 bundle
        let installed = "/Applications/SmartRoute.app"
        if FileManager.default.fileExists(atPath: installed) { return installed }
        return Bundle.main.bundlePath
    }

    func loadAppAutoLaunch() {
        appAutoLaunch = FileManager.default.fileExists(atPath: launchAgentPlist)
    }

    func setAppAutoLaunch(_ on: Bool) {
        configIOError = ""
        let plist = launchAgentPlist
        let app = appPath
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if on {
                    let fm = FileManager.default
                    try fm.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents",
                                          withIntermediateDirectories: true)
                    let xml = """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                    <plist version="1.0">
                    <dict>
                        <key>Label</key>
                        <string>com.user.smartroute.app</string>
                        <key>ProgramArguments</key>
                        <array>
                            <string>/usr/bin/open</string>
                            <string>-a</string>
                            <string>\(app)</string>
                        </array>
                        <key>RunAtLoad</key>
                        <true/>
                    </dict>
                    </plist>

                    """
                    try xml.write(toFile: plist, atomically: true, encoding: .utf8)
                } else {
                    try? FileManager.default.removeItem(atPath: plist)
                }
                DispatchQueue.main.async { self.loadAppAutoLaunch() }
            } catch {
                DispatchQueue.main.async {
                    self.configIOError = "设置开机自启失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 配置导出 / 导入

    /// 导出当前生效的配置（用户配置 + 静态规则）成一个 .conf 文本文件
    // 导出文件里的区段标记。用显式标记而不是靠路径里有没有 "rules" 字样判断——
    // 后者在路径一改就静默失效，规则会被并进配置里。
    private static let confHeader = "# >>> smartroute 配置（KEY=VALUE）>>>"
    private static let rulesHeader = "# >>> smartroute 静态分流规则 >>>"

    func exportConfig() {
        configIOError = ""
        DispatchQueue.global(qos: .userInitiated).async {
            var text = "# smartroute 配置导出  生成于 \(Date())\n"
            text += "# 导入方式：App → 选路设置 → 导入配置\n\n"
            text += Self.confHeader + "\n"
            if let c = try? String(contentsOfFile: ScriptLocator.userConf, encoding: .utf8),
               !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text += c + (c.hasSuffix("\n") ? "" : "\n")
            }
            text += "\n" + Self.rulesHeader + "\n"
            if let r = try? String(contentsOfFile: ScriptLocator.userRules, encoding: .utf8),
               !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text += r + (r.hasSuffix("\n") ? "" : "\n")
            }

            let panel = NSSavePanel()
            panel.nameFieldStringValue = "smartroute-config.conf"
            panel.allowedContentTypes = [.plainText]
            DispatchQueue.main.async {
                presentPanel(panel) { resp in
                    if resp == .OK, let url = panel.url {
                        do {
                            try text.write(to: url, atomically: true, encoding: .utf8)
                            self.configIOError = "✅ 已导出 \(url.lastPathComponent)"
                        } catch {
                            self.configIOError = "导出失败：\(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    /// 从文件导入配置：只认区段标记内的 KEY=VALUE 与规则行，其余忽略
    func importConfig() {
        configIOError = ""
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        DispatchQueue.main.async {
            presentPanel(panel) { resp in
                guard resp == .OK, let url = panel.url else { return }
                do {
                    let raw = try String(contentsOf: url, encoding: .utf8)
                    var conf = "", rules = ""
                    var section = 0   // 0=说明区 1=配置 2=规则
                    for line in raw.components(separatedBy: "\n") {
                        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if t == Self.confHeader  { section = 1; continue }
                        if t == Self.rulesHeader { section = 2; continue }
                        if t.isEmpty || t.hasPrefix("#") { continue }
                        switch section {
                        case 1 where t.contains("="): conf += t + "\n"
                        case 2: rules += t + "\n"
                        default: break
                        }
                    }
                    guard !conf.isEmpty else {
                        self.configIOError = "文件里没找到配置区段（\(Self.confHeader)）"
                        return
                    }
                    // 导入前先校验每一行。以前原样写入然后无条件提示"已导入并生效"，
                    // 而脚本侧只认白名单键、非法值会被忽略——于是用户以为导入成功了，
                    // 守护进程却静默跳过那些键。至少要把被拒的行数说清楚。
                    let (cleanConf, rejected) = Self.sanitizeConf(conf)
                    guard !cleanConf.isEmpty else {
                        self.configIOError = "配置区段里没有合法条目（\(rejected) 行被拒）"
                        return
                    }
                    var rejNote = ""
                    if rejected > 0 {
                        rejNote = "（\(rejected) 行不合法已丢弃）"
                    }
                    // 先备份再覆盖：导入是破坏性操作，留个后悔药
                    let backup = ScriptLocator.userConf + ".bak"
                    if FileManager.default.fileExists(atPath: ScriptLocator.userConf) {
                        try? FileManager.default.copyItem(atPath: ScriptLocator.userConf, toPath: backup)
                    }
                    try cleanConf.write(toFile: ScriptLocator.userConf, atomically: true, encoding: .utf8)
                    if !rules.isEmpty {
                        try rules.write(toFile: ScriptLocator.userRules, atomically: true, encoding: .utf8)
                    }
                    self.loadRoutingConfig()
                    self.loadRules()
                    self.refresh()
                    self.configIOError = "✅ 已导入并生效\(rejNote)（原配置备份为 \(URL(fileURLWithPath: backup).lastPathComponent)）"
                } catch {
                    self.configIOError = "导入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 校验导入的配置：只留白名单键 + 合法值。与 smartroute.sh 的
    /// conf_value_ok / VALID_KEYS 保持一致（脚本侧最终还会再校验一遍，
    /// 但 App 要先说清楚哪些行被丢了，不能假报"已导入并生效"）。
    /// - Returns: (干净内容, 被拒行数)
    static func sanitizeConf(_ raw: String) -> (String, Int) {
        let validKeys: Set<String> = [
            "MODE","OK_N","FAIL_N","COOLDOWN","PROBE_TARGETS","PING_TIMEOUT","NC_TIMEOUT",
            "TLS_PROBE","NOTIFY","AUTO_WIFI_POWER","BALANCE","BALANCE_MODE",
            "FASTEST_SWITCH_RATIO","FASTEST_RECHECK","WIFI_FAILOVER","WIFI_PREFERRED",
            "WIFI_FAILOVER_COOLDOWN","SPEED_TEST_URL","SPEED_TEST_TIMEOUT",
            "SPEED_RECHECK","LATENCY_RECHECK","SPEED_SWITCH_RATIO",
        ]
        let modes: Set<String> = ["auto","ethernet","wifi","speed","latency"]
        let boolKeys: Set<String> = ["TLS_PROBE","NOTIFY","AUTO_WIFI_POWER","BALANCE","WIFI_FAILOVER"]
        let intKeys: Set<String> = ["OK_N","FAIL_N","COOLDOWN","PING_TIMEOUT","NC_TIMEOUT",
            "FASTEST_SWITCH_RATIO","FASTEST_RECHECK","WIFI_FAILOVER_COOLDOWN",
            "SPEED_TEST_TIMEOUT","SPEED_RECHECK","LATENCY_RECHECK","SPEED_SWITCH_RATIO"]
        var out = ""
        var rejected = 0
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            guard let eq = t.firstIndex(of: "=") else { rejected += 1; continue }
            let key = String(t[t.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard validKeys.contains(key) else { rejected += 1; continue }
            var ok = true
            switch key {
            case "MODE":        ok = modes.contains(val)
            case "BALANCE_MODE": ok = (val == "round-robin" || val == "fastest")
            case _ where boolKeys.contains(key): ok = (val == "0" || val == "1")
            case _ where intKeys.contains(key):  ok = !val.isEmpty && val.allSatisfy { $0.isNumber }
            case "SPEED_TEST_URL": ok = !val.isEmpty
            case "WIFI_PREFERRED": ok = !val.contains("\n")
            case "PROBE_TARGETS":  ok = val.allSatisfy { $0.isNumber || $0 == "." || $0 == " " }
            default: break
            }
            if ok { out += "\(key)=\(val)\n" } else { rejected += 1 }
        }
        return (out, rejected)
    }

    func loadRoutingConfig() {
        let conf = loadConfig()
        routeMode = conf["MODE"] ?? "auto"
        routeNotify = conf["NOTIFY"] == "1"
        routeAutoWifi = conf["AUTO_WIFI_POWER"] == "1"
        routeTLS = conf["TLS_PROBE"] == "1"
        routeOkN = Int(conf["OK_N"] ?? "2") ?? 2
        routeFailN = Int(conf["FAIL_N"] ?? "3") ?? 3
        routeCooldown = Int(conf["COOLDOWN"] ?? "45") ?? 45
        speedRecheck = Int(conf["SPEED_RECHECK"] ?? "300") ?? 300
        latencyRecheck = Int(conf["LATENCY_RECHECK"] ?? "60") ?? 60
    }

    func saveRoutingConfig() {
        let current = loadConfig()
        var pending: [(String, String)] = []
        func check(_ key: String, _ value: String) {
            if current[key] != value { pending.append((key, value)) }
        }
        check("MODE", routeMode)
        check("NOTIFY", routeNotify ? "1" : "0")
        check("AUTO_WIFI_POWER", routeAutoWifi ? "1" : "0")
        check("TLS_PROBE", routeTLS ? "1" : "0")
        check("OK_N", String(routeOkN))
        check("FAIL_N", String(routeFailN))
        check("COOLDOWN", String(routeCooldown))

        guard !pending.isEmpty else {
            routingSavedText = "没有需要保存的更改"
            return
        }
        routingSavedText = nil
        busy = true
        setConfigBatch(pending) { [weak self] ok, msg in
            self?.busy = false
            // "≤20 秒生效"是守护进程的轮询周期——没装守护进程时根本没人应用
            // 这条配置，用户照着提示干等，等到以为软件坏了。
            // 先问一句装没装、跑没跑，再决定说什么。
            let daemonLive = ScriptLocator.daemonInstalled && (self?.daemonRunning ?? false)
            self?.routingSavedText = ok
                ? (daemonLive ? "已保存，≤20 秒生效"
                              : "已保存，但守护进程未在运行——自动选路不会生效")
                : "保存失败：\(msg)"
            if ok { self?.refresh() }
        }
    }

    // MARK: - 动作

    func runWatch(completion: @escaping (Bool, String) -> Void) {
        let script = ScriptLocator.scriptPath
        DispatchQueue.global().async {
            do {
                let out = try Privileged.run("'\(script)' watch")
                DispatchQueue.main.async { completion(true, out) }
            } catch {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
            }
        }
    }

    func runDoctor() {
        doctorRunning = true
        DispatchQueue.global().async {
            let (out, _) = Shell.run("'\(ScriptLocator.scriptPath)' doctor", timeout: 90)
            DispatchQueue.main.async {
                self.doctorOutput = out
                self.doctorRunning = false
            }
        }
    }

    func loadLog() {
        // tail 也是外部进程，放后台跑，避免日志页打开时卡一下
        guard beginOp("log") else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { self?.endOp("log") }
            let out = Shell.run("tail -n 300 '\(ScriptLocator.logFile)' 2>/dev/null", timeout: 5).out
            let out2 = Shell.run("tail -n 30 '\(ScriptLocator.daemonOut)' 2>/dev/null", timeout: 5).out
            var combined = out
            if !out2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                combined += "\n\n===== 守护进程 stdout（最近 30 行）=====\n" + out2
            }
            DispatchQueue.main.async { self?.logText = combined }
        }
    }

    func clearLog() {
        busy = true
        DispatchQueue.global().async {
            do {
                _ = try Privileged.run(": > '\(ScriptLocator.logFile)' 2>/dev/null; : > '\(ScriptLocator.daemonOut)' 2>/dev/null; true")
            } catch {}
            DispatchQueue.main.async {
                self.busy = false
                self.loadLog()
            }
        }
    }

    func installDaemon() {
        daemonInstalling = true
        daemonMessage = ""
        // 安装日志的临时位置。用 /tmp 而不是日志目录：这个文件要能被
        // **非特权**的 App 进程读回来展示，日志目录是 root 的读不到。
        let log = "/tmp/smartroute-install.log"
        DispatchQueue.global().async {
            var result = ""
            var failed = false
            do {
                // 用 runWithLog 而不是 run：do shell script 失败时只返回 stderr，
                // install.sh 里那段"请手动执行 launchctl bootstrap / log show"
                // 的排查指引（走 stdout）会被全部吞掉，用户只剩一句裸错误。
                let (out, code) = try Privileged.runWithLog(
                    "bash '\(ScriptLocator.resource("install.sh"))'", logFile: log)
                result = out
                failed = (code != 0)
            } catch PrivilegedError.cancelled {
                // 取消密码框不是失败。说清"什么都没变"，别骂用户一句"失败"，
                // 更别让他不知道到底装没装。
                result = "已取消授权，什么都没有改动。"
                failed = false
            } catch {
                result = "失败: \(error.localizedDescription)"
                failed = true
            }
            DispatchQueue.main.async {
                self.daemonMessage = result
                self.daemonInstalling = false
                self.installFailed = failed
                self.refresh()
            }
        }
    }

    /// 暂停/恢复自动选路。
    ///
    /// 这是用户最基本的心理需求："它老动我网络，我想让它停一下"——
    /// 以前 App 里**完全没有这个入口**，唯一的红色按钮是"彻底卸载"，
    /// 于是用户被逼在"忍受不安"和"连根拔"之间二选一，大多数人只能忍着。
    ///
    /// 实现用 launchctl bootout/bootstrap：bootout 只让 launchd 现在别跑它，
    /// 重启后会自动恢复（plist 还在 /Library/LaunchDaemons）；
    /// 想重启也不恢复得用 disable。所以文案必须说清是"临时"。
    func setDaemonPaused(_ paused: Bool) {
        daemonInstalling = true
        daemonMessage = ""
        let plist = "/Library/LaunchDaemons/com.user.smartroute.plist"
        let cmd = paused
            ? "launchctl bootout system/com.user.smartroute"
            : "launchctl bootstrap system '\(plist)'"
        let log = "/tmp/smartroute-pause.log"
        DispatchQueue.global().async {
            var result = ""
            do {
                let (out, code) = try Privileged.runWithLog(cmd, logFile: log)
                result = out.isEmpty ? (paused ? "已暂停自动选路" : "已恢复自动选路") : out
                if code != 0 { result += "\n(退出码 \(code))" }
            } catch PrivilegedError.cancelled {
                result = "已取消授权，什么都没有改动。"
            } catch {
                result = "失败: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.daemonMessage = result
                self.daemonInstalling = false
                self.daemonPaused = paused
                self.refresh()
            }
        }
    }

    func uninstallDaemon(keepLogs: Bool = false) {
        daemonInstalling = true
        daemonMessage = ""
        let log = "/tmp/smartroute-uninstall.log"
        DispatchQueue.global().async {
            var result = ""
            do {
                // 带 --keep-app：否则会把正在运行的 App 自己删掉。
                // keepLogs：很多人卸载正是因为"用着有问题"，卸完想排查时
                // 日志却被卸载流程自己吃了——留个开关。
                var cmd = "bash '\(ScriptLocator.resource("uninstall.sh"))' --keep-app --yes"
                if keepLogs { cmd += " --keep-logs" }
                let (out, _) = try Privileged.runWithLog(cmd, logFile: log)
                result = out
            } catch PrivilegedError.cancelled {
                result = "已取消授权，什么都没有改动。"
            } catch {
                result = "失败: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.daemonMessage = result
                self.daemonInstalling = false
                self.refresh()
            }
        }
    }

    // MARK: - 网速监控

    func startSpeedMonitor() {
        guard speedTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in self?.tickSpeed() }
        timer.resume()
        speedTimer = timer
    }

    func stopSpeedMonitor() {
        speedTimer?.cancel()
        speedTimer = nil
    }

    private func tickSpeed() {
        // 每秒触发一次，但 stats 偶尔会慢；上次没跑完就跳过本次，
        // 否则慢命令会一个接一个堆积，把机器拖垮
        guard beginOp("speed") else { return }
        defer { endOp("speed") }
        let (out, code) = Shell.run("'\(ScriptLocator.scriptPath)' stats", timeout: 4)
        guard code == 0 else { return }
        let now = Date()
        var parsed: [(dev: String, inB: UInt64, outB: UInt64)] = []
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("time=") else { continue }
            let toks = t.split(separator: " ")
            guard toks.count >= 3 else { continue }
            var fields: [String: String] = [:]
            for tok in toks.dropFirst() {
                if let eq = tok.firstIndex(of: "=") {
                    fields[String(tok[tok.startIndex..<eq])] = String(tok[tok.index(after: eq)...])
                }
            }
            guard let ib = UInt64(fields["ibytes"] ?? ""), let ob = UInt64(fields["obytes"] ?? "") else { continue }
            parsed.append((String(toks[0]), ib, ob))
        }
        guard !parsed.isEmpty else { return }

        var newIn: [String: Double] = [:]
        var newOut: [String: Double] = [:]
        for p in parsed {
            if let prev = lastBytes[p.dev] {
                let dt = now.timeIntervalSince(prev.at)
                if dt > 0.3, p.inB >= prev.inB, p.outB >= prev.outB {
                    newIn[p.dev] = Double(p.inB - prev.inB) / dt / 1024.0
                    newOut[p.dev] = Double(p.outB - prev.outB) / dt / 1024.0
                }
            }
            lastBytes[p.dev] = (p.inB, p.outB, now)
        }
        DispatchQueue.main.async {
            self.speedIn = newIn
            self.speedOut = newOut
            self.monitoredDevices = parsed.map { $0.dev }.sorted()
            for (dev, v) in newIn {
                var arr = self.historyIn[dev] ?? []
                arr.append(v); if arr.count > 60 { arr.removeFirst(arr.count - 60) }
                self.historyIn[dev] = arr
            }
            for (dev, v) in newOut {
                var arr = self.historyOut[dev] ?? []
                arr.append(v); if arr.count > 60 { arr.removeFirst(arr.count - 60) }
                self.historyOut[dev] = arr
            }
        }
    }

    // MARK: - 延迟/丢包

    func loadQuality() {
        // quality 最长可能跑 30 秒，切到"网速与延迟"页就会触发，同样要防重入
        guard beginOp("quality") else { return }
        DispatchQueue.global().async {
            defer { self.endOp("quality") }
            let (out, _) = Shell.run("'\(ScriptLocator.scriptPath)' quality", timeout: 30)
            var dict: [String: QualityInfo] = [:]
            for line in out.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, t.contains("dev=") else { continue }
                let role = String(t.split(separator: " ").first ?? "")
                guard !role.isEmpty else { continue }
                var f: [String: String] = [:]
                for tok in t.split(separator: " ") {
                    if let eq = tok.firstIndex(of: "=") {
                        f[String(tok[tok.startIndex..<eq])] = String(tok[tok.index(after: eq)...])
                    }
                }
                dict[role] = QualityInfo(dev: f["dev"] ?? "", via: f["via"] ?? "",
                                         loss: f["loss"] ?? "?", min: f["min"] ?? "?",
                                         avg: f["avg"] ?? "?", max: f["max"] ?? "?")
            }
            DispatchQueue.main.async { self.quality = dict }
        }
    }

    // MARK: - 双网并发

    func loadBalance() {
        // balance status 要 4-5 秒（含两边延迟测量），切页面/开启后都会调它，
        // 不防重入的话连点几下就堆积一堆探测进程
        guard beginOp("balance") else { return }
        DispatchQueue.global().async {
            // 退出码也要看：超时或 die 时 out 里没有 BALANCE=1，
            // 会把 UI 置成"未开启"、按钮变成"开启"——假状态。
            let (out, code) = Shell.run("'\(ScriptLocator.scriptPath)' balance status", timeout: 25)
            let ok = (code == 0 && !out.isEmpty)
            DispatchQueue.main.async {
                self.endOp("balance")
                self.balanceStatusText = out
                // 读失败时**不能**把 balanceOn 置 false。以前就是这么写的，
                // 于是 balance status 超时（它内含延迟实测，4-5 秒起）时，
                // 界面斩钉截铁显示"未开启"、按钮变成"开启"——而 pf 规则可能
                // 还在跑。用户点一下"开启"，实际是关掉了正在工作的功能。
                // 同代码库的 toggleBalance 处理是对的（"读不到状态就不要动"）。
                if ok {
                    self.balanceOn = out.contains("BALANCE=1")
                    self.balanceUnknown = false
                } else {
                    // 保留上次已知的 balanceOn，只标记"现在不知道"
                    self.balanceUnknown = true
                }
                // "两个接口网关相同（192.168.1.1）" -> 取出网关
                self.balanceSameGateway = ""
                for line in out.components(separatedBy: "\n") {
                    if line.contains("两个接口网关相同") {
                        let t = line.replacingOccurrences(of: "两个接口网关相同", with: "")
                        // 脚本输出用的是**全角括号**（U+FF08/U+FF09）。
                        // 原来找半角 "(" ")"，firstIndex 恒为 nil，
                        // 于是 balanceSameGateway 永远是空——
                        // 「同网关无收益」那条横幅 100% 不显示，
                        // 而它是本项目认定"当前网络下开双网并发有害"的唯一拦阻。
                        // 两种括号都认，免得脚本以后改成半角又失效。
                        var l = t.firstIndex(of: "（")
                        var r = t.firstIndex(of: "）")
                        if l == nil || r == nil {
                            l = t.firstIndex(of: "(")
                            r = t.firstIndex(of: ")")
                        }
                        // l < r 必须成立：否则 t.index(after: l)..<r 会
                        // 构造出 lowerBound > upperBound 的 Range，直接 trap。
                        if let l, let r, l < r {
                            self.balanceSameGateway = String(t[t.index(after: l)..<r])
                        }
                        break
                    }
                }
                if out.contains("分流策略       : 最快线路") { self.balanceMode = "fastest" }
                else { self.balanceMode = "round-robin" }
                // 解析 "实时延迟" 行：    en0      26.8 ms   en1      38.1 ms
                var lat: [String: String] = [:]
                for line in out.components(separatedBy: "\n") {
                    if line.contains(" ms ") && !line.contains("测量中") {
                        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                        // parts: [en0, 26.8, ms, en1, 38.1, ms]
                        if parts.count >= 6 {
                            lat[String(parts[0])] = "\(parts[1]) \(parts[2])"
                            lat[String(parts[3])] = "\(parts[4]) \(parts[5])"
                        }
                    }
                }
                self.balanceLatency = lat
            }
        }
    }

    func setBalance(on: Bool, mode: String? = nil) {
        balanceLoading = true
        balanceMessage = ""
        let script = ScriptLocator.scriptPath
        let modeArg = (on && mode != nil) ? " \(mode!)" : ""
        DispatchQueue.global().async {
            do {
                let out = try Privileged.run("'\(script)' balance \(on ? "on\(modeArg)" : "off")")
                DispatchQueue.main.async {
                    self.balanceLoading = false
                    self.loadBalance()
                    self.balanceMessage = on ? "双网并发已开启" : "双网并发已关闭"
                    if !out.isEmpty { self.balanceMessage = out }
                }
            } catch {
                DispatchQueue.main.async {
                    self.balanceLoading = false
                    var msg = error.localizedDescription
                    // 常见失败给一句可操作提示，避免只看到脚本原文
                    if msg.contains("两个接口都有外网") {
                        msg += "\n\n提示：双网并发要求以太网和 Wi-Fi 当前都能上网。可先在「状态」页点「立即检测」看哪个接口不通；"
                        msg += "若只有一边能上，用「选路设置」切到能上网的那个即可。"
                    } else if msg.contains("另一个 smartroute 正在运行") {
                        msg += "\n\n提示：守护进程每 20 秒自动检测一次，稍等几秒再开启即可。"
                    } else if msg.contains("流量没有走预期接口") {
                        msg += "\n\n提示：本机 macOS 的 pf 可能没有对出站流量生效 route-to（Apple 对该特性支持不完整）。"
                        msg += "\n双网并发是实验特性，遇到这种情况说明本机系统不支持，建议改用「智能选路」的单线路切换。"
                    } else if msg.contains("VPN") {
                        msg += "\n\n提示：VPN 会接管流量走向，与并发分流冲突，请先断开 VPN 再开启。"
                    }
                    self.balanceMessage = "操作失败: \(msg)"
                }
            }
        }
    }

    // MARK: - Wi-Fi 网络选择

    /// 读已保存网络 + 当前信号。免权限，普通 Shell 就够。
    func loadWifi() {
        // in-flight 守卫：Wi-Fi 页每 5 秒轮询一次，加上 onAppear、定时器、
        // "刷新列表"按钮、join 成功回调，很容易并发跑多份。
        // 两个实例的完成顺序不保证，旧结果可能覆盖新结果（显示过期信号）。
        guard beginOp("wifi") else { return }
        let script = ScriptLocator.scriptPath
        DispatchQueue.global().async {
            // 用 --raw：一行一个 SSID，不带序号。带序号的格式人看着舒服，
            // 但 SSID 本身可以叫 "1. CZ-305"，按 "数字. " 剥前缀会剥错。
            let saved = WifiParsing.savedNetworks(
                Shell.run("'\(script)' wifi list --raw", timeout: 8).out)
            // 一次调用拿全信号/信道/速率/噪声。这里曾经为了速率和噪声去跑两次
            // `smartroute status`（各约 1.8 秒），Wi-Fi 页刷新要 5 秒——
            // system_profiler 一次就要 1.7 秒，重复调它就是慢的根源。
            var signal = "", channel = "", bars = 0, rate = "", noise = ""
            let curOut = Shell.run("'\(script)' wifi current --raw", timeout: 8).out
            if let cur = WifiParsing.currentSignal(curOut) {
                signal = cur.rssi; channel = cur.channel; bars = cur.bars
            }
            if let r = WifiParsing.capture(curOut, pattern: "rate=([0-9]+)") { rate = r }
            if let n = WifiParsing.capture(curOut, pattern: "noise=(-?[0-9]+)") { noise = n }
            defer { self.endOp("wifi") }
            DispatchQueue.main.async {
                self.wifiSaved = saved
                self.wifiSignal = signal
                self.wifiChannel = channel
                self.wifiBars = bars
                self.wifiRate = rate
                self.wifiNoise = noise
            }
        }
    }

    /// 扫描附近网络。thorough=false 约 1 秒（给轮询用），true 约 10 秒（给按钮用）。
    ///
    /// App 自己缓存结果而不是每次轮询都扫：扫描要 1 秒以上，而轮询是几秒一次，
    /// 每次都扫既慢又费电。用户点「重新扫描」才强制刷。
    func loadWifiScan(force: Bool = false, thorough: Bool = false) {
        if wifiScanning { return }
        // 30 秒内的缓存直接复用
        if !force, let at = wifiScanAt, Date().timeIntervalSince(at) < 30 { return }

        let script = ScriptLocator.scriptPath
        wifiScanning = true
        DispatchQueue.global().async {
            let cmd = thorough
                ? "'\(script)' wifi scan"
                : "'\(script)' wifi scan --quick"
            // 退出码也要看：超时时 out 只有"(命令超时 15 秒)"，
            // 解析出空列表，界面会显示"附近没有已保存的网络在范围"——
            // 一个确定性的结论，而实际只是没扫到。而且 wifiScanAt 照写，
            // 30 秒内不会重试，用户盯着错误结论干等。
            let (out, code) = Shell.run(cmd, timeout: thorough ? 40 : 15)

            let list = WifiParsing.nearbyNetworks(out)
            var note = ""
            if code != 0 {
                note = "扫描失败（退出码 \(code)），不是「附近没有网络」。稍后重试，或点「完整扫描」。"
            } else if let n = WifiParsing.scanUnknownCount(out) {
                note = "有 \(n) 个网络未能确认（系统扫描有冷却）"
            }
            DispatchQueue.main.async {
                self.wifiNearby = list
                self.wifiScanNote = note
                self.wifiScanning = false
                // 失败时不写时间戳，让用户能立刻重试
                if code == 0 { self.wifiScanAt = Date() }
            }
        }
    }

    /// 连接到一个 Wi-Fi。已保存的网络不用输密码。
    func wifiJoin(_ ssid: String) {
        guard wifiJoining.isEmpty else { return }   // 正在连另一个，别并发
        wifiJoining = ssid
        wifiMessage = ""
        let script = ScriptLocator.scriptPath
        DispatchQueue.global().async {
            do {
                let out = try Privileged.run("'\(script)' wifi join \(Shell.quote(ssid))")
                DispatchQueue.main.async {
                    self.wifiJoining = ""
                    self.loadWifi()
                    self.wifiMessage = out.isEmpty ? "已连接到 \(ssid)" : out
                    self.wifiMessageFailed = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.wifiJoining = ""
                    var msg = error.localizedDescription
                    if msg.contains("连接") && msg.contains("失败") {
                        msg += "\n\n提示：只有「已保存过」的网络才能一键连接（密码在系统钥匙串里）。"
                        msg += "\n新网络请先在系统菜单栏的 Wi-Fi 里连一次，之后这里就能一键切了。"
                    }
                    self.wifiMessage = "切换失败: \(msg)"
                    self.wifiMessageFailed = true
                }
            }
        }
    }

    /// 逐个试连已保存网络，自动连上第一个能上网的
    func wifiTryAll() {
        wifiLoading = true
        wifiMessage = ""
        let script = ScriptLocator.scriptPath
        DispatchQueue.global().async {
            do {
                let out = try Privileged.run("'\(script)' wifi tryall")
                DispatchQueue.main.async {
                    self.wifiLoading = false
                    self.loadWifi()
                    self.wifiMessage = out
                }
            } catch {
                DispatchQueue.main.async {
                    self.wifiLoading = false
                    self.wifiMessage = "失败: \(error.localizedDescription)"
                    self.wifiMessageFailed = true
                }
            }
        }
    }

    /// 开关自动故障转移
    func setWifiFailover(on: Bool) {
        wifiLoading = true
        wifiMessage = ""
        let script = ScriptLocator.scriptPath
        DispatchQueue.global().async {
            do {
                _ = try Privileged.run("'\(script)' wifi auto \(on ? "on" : "off")")
                DispatchQueue.main.async {
                    self.wifiLoading = false
                    self.loadWifiFailover()
                    self.wifiMessage = on ? "已开启自动切换" : "已关闭自动切换"
                    self.wifiMessageFailed = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.wifiLoading = false
                    self.wifiMessage = "设置失败: \(error.localizedDescription)"
                    self.wifiMessageFailed = true
                }
            }
        }
    }

    /// 读守护进程缓存的实测结果（state 文件里的 speed_<dev> / lat_<dev>）
    func loadMeasurements() {
        guard beginOp("measurements") else { return }
        let script = ScriptLocator.scriptPath
        DispatchQueue.global().async {
            // 直接读 state 文件比再起一个进程快；App 已在轮询里调这个，要省着点
            var es = "未测", ws = "未测", el = "未测", wl = "未测"
            let (st, code) = Shell.run("'\(script)' measurements", timeout: 6)
            for line in st.components(separatedBy: "\n") {
                if line.hasPrefix("speed:") {
                    let p = line.dropFirst(6).components(separatedBy: "=")
                    if p.count == 2 {
                        if p[0] == "eth" { es = p[1] } else if p[0] == "wifi" { ws = p[1] }
                    }
                } else if line.hasPrefix("latency:") {
                    // 必须按前缀长度取，不能写死数字："latency:" 是 8 个字符，
                    // 原来写死 9 把 e 也吃掉了，得到 "th=14.3 ms"，
                    // p[0] 永远匹配不上 "eth"/"wifi"——实测延迟恒显示"未测"。
                    // 写死数字这类错很容易再犯，所以用 "latency:".count。
                    let p = line.dropFirst("latency:".count).components(separatedBy: "=")
                    if p.count == 2 {
                        if p[0] == "eth" { el = p[1] } else if p[0] == "wifi" { wl = p[1] }
                    }
                }
            }
            defer { self.endOp("measurements") }
            DispatchQueue.main.async {
                // 读取失败要和"真的没测过"区分开。以前失败时四项都是初值"未测"，
                // 界面看着跟没测过一模一样——用户不知道该不该点"重新测量"。
                if code != 0 {
                    let m = "读取失败"
                    self.ethSpeed = m; self.wifiSpeed = m
                    self.ethLatency = m; self.wifiLatency = m
                    self.measurementsNote = "measurements 命令失败（退出码 \(code)），可能是脚本被占用"
                } else {
                    self.ethSpeed = es; self.wifiSpeed = ws
                    self.ethLatency = el; self.wifiLatency = wl
                    self.measurementsNote = ""
                }
            }
        }
    }

    /// 立即重新测量（用户等不及 SPEED_RECHECK 时点这个）
    func remeasureNow() {
        remeasuring = true
        let script = ScriptLocator.scriptPath
        DispatchQueue.global().async {
            do {
                _ = try Privileged.run("'\(script)' measure now")
                DispatchQueue.main.async {
                    self.remeasuring = false
                    self.loadMeasurements()
                }
            } catch {
                DispatchQueue.main.async {
                    self.remeasuring = false
                }
            }
        }
    }

    /// 保存优先尝试列表（逗号分隔）
    func saveWifiPreferred() {
        // 用户多半会习惯打中文逗号，先规整成半角逗号。
        // 但**空格不能静默去掉**：脚本侧用空白拆分（for ssid in $pref $saved），
        // 格式本身表达不了带空格的 SSID。以前这里直接 replace(" ", "")，
        // 于是 "A9 5G" 被静默改成 "A95G"——保存成功、列表也显示 A95G，
        // 但永远匹配不上系统里存的 "A9 5G"，"优先列表已保存"是假成功。
        // 现在：含空格就明确拒绝，让用户知道这个网络名进不了优先列表。
        let normalized = wifiPreferred.replacingOccurrences(of: "，", with: ",")
        if normalized.contains(" ") {
            wifiMessage = "网络名里含空格，无法加入优先列表（脚本用空格分隔多项）。可改用系统菜单栏 Wi-Fi 调整顺序。"
            wifiMessageFailed = true
            return
        }
        wifiPreferred = normalized
        wifiMessage = ""
        setConfigBatch([("WIFI_PREFERRED", Shell.quote(normalized))]) { ok, msg in
            DispatchQueue.main.async {
                self.wifiMessage = ok ? (normalized.isEmpty ? "已恢复默认顺序" : "优先列表已保存") : "保存失败: \(msg)"
                self.wifiMessageFailed = !ok
                self.loadWifiFailover()
            }
        }
    }

    /// 读自动故障转移开关与优先列表
    func loadWifiFailover() {
        guard beginOp("wififailover") else { return }
        let script = ScriptLocator.scriptPath
        DispatchQueue.global().async {
            var on = false, preferred = ""
            let stOut = Shell.run("'\(script)' wifi auto status", timeout: 8).out
            if !stOut.isEmpty {
                for line in stOut.components(separatedBy: "\n") {
                    if line.hasPrefix("WIFI_FAILOVER=") {
                        on = line.replacingOccurrences(of: "WIFI_FAILOVER=", with: "") == "1"
                    } else if line.hasPrefix("优先列表:") {
                        let v = line.replacingOccurrences(of: "优先列表:", with: "").trimmingCharacters(in: .whitespaces)
                        preferred = (v == "(空，按系统保存顺序)") ? "" : v
                    }
                }
            }
            defer { self.endOp("wififailover") }
            DispatchQueue.main.async {
                self.wifiFailoverOn = on
                self.wifiPreferred = preferred
            }
        }
    }

    // MARK: - 分流规则

    func loadRules() {
        guard beginOp("rules") else { return }
        DispatchQueue.global().async {
            defer { self.endOp("rules") }
            let (out, _) = Shell.run("'\(ScriptLocator.scriptPath)' rule list", timeout: 6)
            var items: [RouteRule] = []
            for line in out.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                let toks = t.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard toks.count >= 4, toks[1] == "->" else { continue }
                let status = toks[3].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                items.append(RouteRule(cidr: toks[0], dev: toks[2], status: status))
            }
            DispatchQueue.main.async { self.rules = items }
        }
    }

    /// CIDR 白名单校验。addRule 和 removeRule 必须用同一套——
    /// 以前只有 addRule 校验，removeRule 直接把 cidr 插进命令，
    /// 而那个 cidr 来自对 rule list 输出的解析（内容可被预置的 rules 文件影响），
    /// 点一下删除按钮就能以 App 用户身份执行注入的命令。
    private func validCidr(_ cidr: String) -> Bool {
        cidr.range(of: #"^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$"#, options: .regularExpression) != nil
    }
    private func validDev(_ dev: String) -> Bool {
        dev.range(of: #"^[a-z][a-z0-9]*$"#, options: .regularExpression) != nil
    }

    func addRule(cidr: String, dev: String) {
        // 白名单校验，防止注入
        let cidrOK = validCidr(cidr)
        let devOK = validDev(dev)
        guard cidrOK, devOK else {
            ruleMessage = "格式不正确：CIDR 形如 10.0.0.0/8，接口形如 en0"
            return
        }
        ruleMessage = ""
        busy = true
        DispatchQueue.global().async {
            // 白名单之外再加一层引号，双保险
            let (out, code) = Shell.run("'\(ScriptLocator.scriptPath)' rule add \(Shell.quote(cidr)) \(Shell.quote(dev))", timeout: 8)
            DispatchQueue.main.async {
                self.busy = false
                self.ruleMessage = (code == 0) ? "已添加 \(cidr) -> \(dev)，守护进程 ≤20 秒内应用" : "添加失败：\(out)"
                if code == 0 { self.newRuleCidr = ""; self.loadRules() }
            }
        }
    }

    func removeRule(cidr: String) {
        // 必须和 addRule 一样校验。以前这里没有，cidr 来自对 rule list
        // 输出的解析，而那个输出反映的是可被他人预置的 rules 文件——
        // 点删除按钮就等于把文件内容插进 shell 命令。
        guard validCidr(cidr) else {
            ruleMessage = "CIDR 格式不正确：\(cidr)"
            return
        }
        ruleMessage = ""
        busy = true
        DispatchQueue.global().async {
            let (out, code) = Shell.run("'\(ScriptLocator.scriptPath)' rule del \(Shell.quote(cidr))", timeout: 8)
            DispatchQueue.main.async {
                self.busy = false
                self.ruleMessage = (code == 0) ? "已删除 \(cidr)" : "删除失败：\(out)"
                self.loadRules()
            }
        }
    }

    // MARK: - 内部

    static func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

// MARK: - 解析辅助

private func parseHardwarePorts(_ text: String) -> [(port: String, device: String)] {
    var result: [(port: String, device: String)] = []
    var port = ""
    for line in text.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("Hardware Port: ") {
            port = String(t.dropFirst("Hardware Port: ".count))
        } else if t.hasPrefix("Device: ") {
            let dev = String(t.dropFirst("Device: ".count))
            if !port.isEmpty && !dev.isEmpty {
                result.append((port, dev))
                port = ""
            }
        }
    }
    return result
}

private func parseServiceOrder(_ text: String) -> [ServiceEntry] {
    var result: [ServiceEntry] = []
    var pendingName: String?
    var pendingEnabled = true
    for line in text.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("(") && t.contains(") ") && !t.hasPrefix("(Hardware Port") {
            if let r = t.range(of: ") ") {
                let marker = String(t[t.startIndex..<r.lowerBound])
                pendingName = String(t[r.upperBound...])
                pendingEnabled = (marker != "(*)")
            }
        } else if t.hasPrefix("(Hardware Port:") {
            if let dr = t.range(of: "Device: ") {
                let dev = String(t[dr.upperBound...]).replacingOccurrences(of: ")", with: "")
                if let name = pendingName {
                    result.append(ServiceEntry(name: name, device: dev, enabled: pendingEnabled))
                    pendingName = nil
                }
            }
        }
    }
    return result
}

private func role(of port: String) -> String {
    let p = port.lowercased()
    if p.contains("wi-fi") || p.contains("wifi") || p.contains("airport") || p.contains("无线") { return "Wi-Fi" }
    if p.contains("ethernet") || p.contains("以太") || p.contains("lan") { return "以太网" }
    return "其他"
}

/// 一次 ifconfig 解析出所有接口的 IPv4 地址
///
/// ifconfig 输出形如：
///   en0: flags=8863<UP,BROADCAST,...> mtu 1500
///       inet 192.168.1.36 netmask 0xffffff00 broadcast 192.168.1.255
///       inet6 fe80::...%en0 prefixlen 64 scopeid 0x4
/// 接口头行以非空白字符开头（en0: / utun4: / ...），其下的 "inet " 行给出 IPv4。
private func allIPAddresses() -> [String: String] {
    let out = Shell.run("ifconfig", timeout: 5).out
    var result: [String: String] = [:]
    var curDev = ""
    for line in out.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        // 接口头行：行首不是空白 → 形如 "en0: flags=..."
        if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
            let dev = String(t.prefix(while: { $0 != ":" }))
            if !dev.isEmpty { curDev = dev }
            continue
        }
        // 只取 IPv4（"inet " 不会匹配到 "inet6 "）
        if t.hasPrefix("inet "), !curDev.isEmpty, result[curDev] == nil {
            let toks = t.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if toks.count >= 2 { result[curDev] = String(toks[1]) }
        }
    }
    return result
}

/// 一次 netstat -rn 拿到所有接口的默认网关
///
/// 原来对每个服务跑一次 `networksetup -getinfo <服务名>`（N 个进程），
/// 现在一个进程就够：路由表里每个接口的 default 行就是它的实际出口网关。
private func allGateways() -> [String: String] {
    let out = Shell.run("netstat -rn", timeout: 5).out
    var result: [String: String] = [:]
    for line in out.components(separatedBy: "\n") {
        let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // default <gateway> <flags> <netif> ...
        guard toks.count >= 4, toks[0] == "default" else { continue }
        let gw = toks[1], netif = toks[3]
        if gw != "link", !gw.isEmpty, result[netif] == nil { result[netif] = gw }
    }
    return result
}

private func router(of service: String) -> String {
    guard !service.isEmpty, service != "-" else { return "" }
    let out = Shell.run("networksetup -getinfo '\(service)'", timeout: 5).out
    for line in out.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("Router:") {
            let v = String(t.dropFirst("Router:".count)).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
    }
    return ""
}

private func readKeyValues(_ path: String) -> [String: String] {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var dict: [String: String] = [:]
    for line in content.components(separatedBy: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1)
        if parts.count == 2 {
            dict[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
    }
    return dict
}

private func readMode() -> String {
    for path in [ScriptLocator.userConf, ScriptLocator.systemConf] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        for line in content.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("MODE=") {
                return String(t.dropFirst("MODE=".count))
            }
        }
    }
    return "auto"
}

private func humanize(_ epoch: String) -> String {
    guard let e = Double(epoch), e > 0 else { return "从未" }
    let d = Date().timeIntervalSince1970 - e
    if d < 60 { return "\(Int(d)) 秒前" }
    if d < 3600 { return "\(Int(d / 60)) 分钟前" }
    if d < 86400 { return "\(Int(d / 3600)) 小时前" }
    return "\(Int(d / 86400)) 天前"
}

/// 守护进程运行态。
///
/// 为什么必须有三态而不是布尔：这个 plist 用的是 StartInterval=20，
/// 意味着进程**大部分时间并不存在**（只在每次运行的瞬间活着），
/// 所以 pgrep 几乎永远查不到——它不能作为"没在跑"的证据。
/// 唯一可用的非特权信号是日志 mtime（每 20 秒写一行）。
/// 而 Mac 睡眠期间 launchd 不跑 job，唤醒后要等最多 20 秒才写第一行：
/// 用户刚唤醒就打开 App 时，mtime 是旧的——只看布尔就会误报"未在运行"。
/// 误报的代价很大：会让人以为自动选路没在工作，甚至去重装。
/// 所以加一个"等待下次检测"的中间态，只有**确实**长时间没更新才告警。
enum DaemonState {
    case running        // 日志新鲜，确实在跑
    case waiting        // 日志略旧：刚唤醒或刚装完，等下一次检测
    case stopped        // 日志长时间没更新，或根本没有日志文件
}

private func daemonState() -> DaemonState {
    // 守护进程每 20 秒往 smartroute.out 写一行，看文件新鲜度。
    if let attrs = try? FileManager.default.attributesOfItem(atPath: ScriptLocator.daemonOut),
       let mtime = attrs[.modificationDate] as? Date {
        let age = Date().timeIntervalSince(mtime)
        // 90 秒 = 4~5 个轮询周期，正常情况一定更新过了
        if age < 90 { return .running }
        // 5 分钟内：可能是刚唤醒（唤醒后最多 20 秒就会写），
        // 也可能是刚装完还没跑第一次。这时候不能下结论。
        if age < 300 { return .waiting }
        return .stopped
    }
    // 没有日志文件：可能是从没跑过（刚装完、还没到第一次），
    // 也可能是被 bootout 了。用进程表兜一下——虽然 StartInterval 下
    // 大部分时间查不到，但恰好撞上它在跑就能确认"是活的"。
    let (_, code) = Shell.run("pgrep -f 'smartroute watch'", timeout: 5)
    return code == 0 ? .running : .stopped
}

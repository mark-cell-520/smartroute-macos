import Foundation
import SwiftUI

// MARK: - 页面枚举

enum AppPage: String, CaseIterable, Identifiable {
    case status, speed, balance, rules, routing, doctor, log, daemon, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .status:  return "状态"
        case .speed:   return "网速与延迟"
        case .balance: return "双网并发"
        case .rules:   return "分流规则"
        case .routing: return "选路设置"
        case .doctor:  return "体检"
        case .log:     return "日志"
        case .daemon:  return "守护进程"
        case .about:   return "关于"
        }
    }
    var icon: String {
        switch self {
        case .status:  return "dot.radiowaves.left.and.right"
        case .speed:   return "speedometer"
        case .balance: return "arrow.triangle.branch"
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
    var ethOK: String = "-"
    var wifiOK: String = "-"
    var streakEth: String = "-"
    var streakWifi: String = "-"
    var lastSwitch: String = "从未"
    var switchCount: String = "0"
    var mode: String = "auto"
    var daemonRunning: Bool = false
    var daemonScriptOutdated: Bool = false
    var lastUpdated: String = ""
}

final class NetworkModel: ObservableObject {

    /// 供菜单栏（AppDelegate）复用同一个实例
    static weak var shared: NetworkModel?

    // MARK: 基础状态
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
    @Published var daemonInstalling = false

    // MARK: 选路表单
    @Published var routeMode = "auto"
    @Published var routeNotify = false
    @Published var routeAutoWifi = false
    @Published var routeTLS = true
    @Published var routeOkN = 2
    @Published var routeFailN = 3
    @Published var routeCooldown = 45

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
    @Published var pendingBalanceMode = "round-robin"   // 用户在下拉里选的、尚未生效的策略
    @Published var balanceLatency: [String: String] = [:]   // 设备名 -> "14.3 ms"
    @Published var balanceLoading = false
    @Published var balanceMessage = ""

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

        var gwReachable = false
        if !defGw.isEmpty {
            let (_, code) = Shell.run("ping -c 1 -W 800 \(defGw)", timeout: 3)
            gwReachable = (code == 0)
        }

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
        snapshot.daemonRunning = daemonIsRunning()
        snapshot.daemonScriptOutdated = ScriptLocator.daemonScriptOutdated
        snapshot.lastUpdated = Self.timeString()
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

    func loadRoutingConfig() {
        let conf = loadConfig()
        routeMode = conf["MODE"] ?? "auto"
        routeNotify = conf["NOTIFY"] == "1"
        routeAutoWifi = conf["AUTO_WIFI_POWER"] == "1"
        routeTLS = conf["TLS_PROBE"] == "1"
        routeOkN = Int(conf["OK_N"] ?? "2") ?? 2
        routeFailN = Int(conf["FAIL_N"] ?? "3") ?? 3
        routeCooldown = Int(conf["COOLDOWN"] ?? "45") ?? 45
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
            self?.routingSavedText = ok ? "已保存，≤20 秒生效" : "保存失败：\(msg)"
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
        DispatchQueue.global().async {
            var result = ""
            do {
                result = try Privileged.run("bash '\(ScriptLocator.resource("install.sh"))'")
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

    func uninstallDaemon() {
        daemonInstalling = true
        daemonMessage = ""
        DispatchQueue.global().async {
            var result = ""
            do {
                result = try Privileged.run("bash '\(ScriptLocator.resource("uninstall.sh"))'")
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
            let (out, _) = Shell.run("'\(ScriptLocator.scriptPath)' balance status", timeout: 25)
            DispatchQueue.main.async {
                self.endOp("balance")
                self.balanceStatusText = out
                self.balanceOn = out.contains("BALANCE=1")
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

    func addRule(cidr: String, dev: String) {
        // 白名单校验，防止注入
        let cidrOK = cidr.range(of: #"^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$"#, options: .regularExpression) != nil
        let devOK = dev.range(of: #"^[a-z][a-z0-9]*$"#, options: .regularExpression) != nil
        guard cidrOK, devOK else {
            ruleMessage = "格式不正确：CIDR 形如 10.0.0.0/8，接口形如 en0"
            return
        }
        ruleMessage = ""
        busy = true
        DispatchQueue.global().async {
            let (out, code) = Shell.run("'\(ScriptLocator.scriptPath)' rule add \(cidr) \(dev)", timeout: 8)
            DispatchQueue.main.async {
                self.busy = false
                self.ruleMessage = (code == 0) ? "已添加 \(cidr) -> \(dev)，守护进程 ≤20 秒内应用" : "添加失败：\(out)"
                if code == 0 { self.newRuleCidr = ""; self.loadRules() }
            }
        }
    }

    func removeRule(cidr: String) {
        ruleMessage = ""
        busy = true
        DispatchQueue.global().async {
            let (out, code) = Shell.run("'\(ScriptLocator.scriptPath)' rule del \(cidr)", timeout: 8)
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

private func daemonIsRunning() -> Bool {
    // 方式一：守护进程每 20 秒往 smartroute.out 写一行，看文件新鲜度
    if let attrs = try? FileManager.default.attributesOfItem(atPath: ScriptLocator.daemonOut),
       let mtime = attrs[.modificationDate] as? Date {
        if Date().timeIntervalSince(mtime) < 90 { return true }
    }
    // 方式二：进程表
    let (_, code) = Shell.run("pgrep -f 'smartroute watch'", timeout: 5)
    return code == 0
}

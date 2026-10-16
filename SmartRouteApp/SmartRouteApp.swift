import SwiftUI
import AppKit

@main
struct SmartRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("SmartRoute 智能选路") {
            MainView()
                .frame(minWidth: 780, minHeight: 560)
        }
        .defaultSize(width: 820, height: 600)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "network", accessibilityDescription: "SmartRoute")
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "打开面板", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(.separator())
        // 五个模式都要有。以前只有 auto/ethernet/wifi 三个，而设置页和 README
        // 都有五个——于是用户在 App 里选了"网速优先"，菜单栏点一下"自动模式"
        // 就把它静默覆盖了，且菜单上看不出当前是哪个（没有勾选）。
        // 这是个"影子控制台"：看起来能控制，实际会悄悄改掉你刚设的东西。
        menu.addItem(withTitle: "自动模式", action: #selector(setMode(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "强制走 Wi-Fi", action: #selector(setMode(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "强制走以太网", action: #selector(setMode(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "网速优先", action: #selector(setMode(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "延时优先", action: #selector(setMode(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "双网并发：开 / 关", action: #selector(toggleBalance), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // target 只能设给**实现了该 action** 的对象。"退出"项的 action 是
        // NSApplication.terminate:，而 AppDelegate 没有实现它——以前对全部条目
        // 一律设 target = self，AppKit 发现 target 不响应 action 就把该条目
        // 永久禁用（实测 enabled=false），用户只能走主菜单 ⌘Q 或 Dock 退出。
        // "退出"保持 target = nil，action 会沿 responder chain 找到
        // NSApplication.terminate:（系统默认就有）。
        // tag = 模式在 modeList 里的下标。用下标而不是写死的数字，
        // 加模式时只改 modeList 一处，不会出现 tag 和标题对不上的情况。
        for (index, menuItem) in menu.items.enumerated() {
            if let tag = Self.modeList.firstIndex(of: menuItem.title) {
                menuItem.tag = tag
                menuItem.target = self
            }
            // 其余条目（含"退出"）不设 target：AppKit 发现 target 不响应 action
            // 会把条目永久禁用，"退出"的 action 沿 responder chain 就能找到。
        }
        balanceItem = menu.item(at: 8)
        modeMenu = menu
        item.menu = menu
        statusItem = item
        // 定时刷新勾选状态。没有这一步，用户在 App 里改了模式，
        // 菜单栏还勾着旧的那个——又是一个"界面说的和实际不一样"。
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshMenuState()
        }
    }

    /// 模式标识 -> 菜单标题。顺序即 tag，两处都从这里取。
    static let modeList = ["自动模式", "强制走 Wi-Fi", "强制走以太网", "网速优先", "延时优先"]
    /// 模式标识 -> 中文名（通知用）。以前通知里直接弹 "ethernet" 这种英文，
    /// 非技术用户看不懂自己刚被切成了什么。
    static let modeNames = ["auto": "自动模式", "ethernet": "强制走以太网",
                            "wifi": "强制走 Wi-Fi", "speed": "网速优先",
                            "latency": "延时优先"]

    private var modeMenu: NSMenu?

    /// 按当前模式打勾。当前模式从 Model 读（它每次 refresh 都会更新），
    /// 读不到就全不打勾——不打勾比打错勾好，打错会让人以为选错了东西。
    func refreshMenuState() {
        guard let menu = modeMenu, let model = NetworkModel.shared else { return }
        let cur = model.mode
        let curTitle = Self.modeNames[cur] ?? "自动模式"
        for item in menu.items {
            guard let tag = Self.modeList.firstIndex(of: item.title) else { continue }
            _ = tag
            item.state = (item.title == curTitle) ? .on : .off
        }
        balanceItem?.state = model.balanceOn ? .on : .off
    }

    /// 失去焦点时停掉每秒采样：用户切到别的 App 时，没人看曲线，
    /// 没必要每秒还跑一个子进程（省电、也让前台 App 更流畅）。
    func applicationDidResignActive(_ notification: Notification) {
        NetworkModel.shared?.stopSpeedMonitor()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NetworkModel.shared?.startSpeedMonitor()
        // 失焦期间没采集，切回前台立刻补一次，避免看到过期数据
        NetworkModel.shared?.refresh()
    }

    private var balanceItem: NSMenuItem?

    @objc private func toggleBalance() {
        guard NetworkModel.shared != nil else {
            notify(title: "SmartRoute", body: "请先打开 SmartRoute 面板")
            return
        }
        DispatchQueue.global().async {
            // 退出码必须看。balance status 超时（这里只给 8 秒，而它含两边
            // 延迟实测）或中途 die 时，out 里不会有 "BALANCE=1"，
            // 于是 on=false——然后下面拿这个未验证的状态取反去执行开关：
            // 并发实际开着，用户想关，App 却去执行 balance on，
            // 反复点毫无反应，pf 分流规则一直留着。
            let (out, code) = Shell.run("'\(ScriptLocator.scriptPath)' balance status", timeout: 8)
            let ok = (code == 0 && !out.isEmpty)
            let on = ok && out.contains("BALANCE=1")
            DispatchQueue.main.async {
                guard ok else {
                    // 读不到状态就不要动——宁可提示重试，也不要凭猜做反向操作
                    self.notify(title: "SmartRoute", body: "读不到双网并发状态，请重试")
                    return
                }
                // 不在 @Sendable 闭包里捕获 model（非 Sendable 会告警）；
                // 回到主线程后再从 shared 取，等价且干净
                NetworkModel.shared?.setBalance(on: !on)
            }
        }
    }

    @objc private func openPanel() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        // 标题 -> 模式标识。用标题反查而不是按下标，加模式时不会错位。
        guard let title = Self.modeList.first(where: { $0 == sender.title }),
              let mode = Self.modeNames.first(where: { $0.value == title })?.key else { return }
        DispatchQueue.global().async {
            let (out, code) = Shell.run("'\(ScriptLocator.configScriptPath)' set \(mode)")
            DispatchQueue.main.async {
                // 中文名，别弹 "ethernet" —— 非技术用户看不懂自己刚被切成了什么
                let name = Self.modeNames[mode] ?? mode
                let body = code == 0 ? "选路模式已切换为 \(name)" : "切换失败：\(out.prefix(150))"
                self.notify(title: "SmartRoute", body: body)
                NetworkModel.shared?.refresh()
                self.refreshMenuState()
            }
        }
    }

    private func notify(title: String, body: String) {
        // 必须先转义反斜杠再转义双引号——顺序反了会二次转义。
        // 只转义 " 不够：AppleScript 只认 \n \t \r \" \\ 五种转义，
        // 遇到 \d、\0 这类直接报 -2741 编译错误，而 error 参数没人检查，
        // 结果就是通知静默不弹。body 来自脚本输出，含反斜杠很常见。
        // （bash 侧 notify() 的同类问题已经修了，这里是对齐。）
        let escaped = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "display notification \"\(escaped)\" with title \"\(title)\"")?.executeAndReturnError(&error)
    }
}

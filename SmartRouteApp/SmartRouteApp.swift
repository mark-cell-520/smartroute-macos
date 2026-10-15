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
        menu.addItem(withTitle: "自动模式", action: #selector(setMode(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "强制走 Wi-Fi", action: #selector(setMode(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "强制走以太网", action: #selector(setMode(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "双网并发：开 / 关", action: #selector(toggleBalance), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for (index, menuItem) in menu.items.enumerated() {
            menuItem.target = self
            switch index {
            case 2: menuItem.tag = 0   // auto
            case 3: menuItem.tag = 2   // wifi
            case 4: menuItem.tag = 1   // ethernet
            default: break
            }
        }
        balanceItem = menu.item(at: 6)

        item.menu = menu
        statusItem = item
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
        guard let model = NetworkModel.shared else {
            notify(title: "SmartRoute", body: "请先打开 SmartRoute 面板")
            return
        }
        DispatchQueue.global().async {
            let (out, _) = Shell.run("'\(ScriptLocator.scriptPath)' balance status", timeout: 8)
            let on = out.contains("BALANCE=1")
            DispatchQueue.main.async {
                model.setBalance(on: !on)
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
        let modes = ["auto", "ethernet", "wifi"]
        let mode = modes[sender.tag]
        DispatchQueue.global().async {
            let (out, code) = Shell.run("'\(ScriptLocator.configScriptPath)' set \(mode)")
            DispatchQueue.main.async {
                let body = code == 0 ? "选路模式已切换为 \(mode)" : "切换失败：\(out.prefix(150))"
                self.notify(title: "SmartRoute", body: body)
            }
        }
    }

    private func notify(title: String, body: String) {
        let escaped = body.replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "display notification \"\(escaped)\" with title \"\(title)\"")?.executeAndReturnError(&error)
    }
}

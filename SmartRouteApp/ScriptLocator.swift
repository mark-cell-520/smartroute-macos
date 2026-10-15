import Foundation

/// smartroute 相关路径（App 内置脚本在 Bundle Resources 中）
enum ScriptLocator {
    static let installedScript = "/usr/local/bin/smartroute"
    static let userConf = "/Users/Shared/smartroute.conf"
    static let systemConf = "/etc/smartroute.conf"
    static let stateFile = "/var/db/smartroute/state"
    static let logFile = "/var/log/smartroute.log"
    static let daemonOut = "/var/log/smartroute.out"
    static let daemonErr = "/var/log/smartroute.err"
    static let daemonPlist = "/Library/LaunchDaemons/com.user.smartroute.plist"
    static let pfAnchor = "com.user.smartroute"

    static var userRules: String {
        userConf.replacingOccurrences(of: "smartroute.conf", with: "smartroute.rules")
    }

    static var resourceDirectory: String {
        Bundle.main.resourcePath ?? ""
    }

    static func resource(_ name: String) -> String {
        resourceDirectory + "/" + name
    }

    /// 特权命令（探测/并发/规则）一律使用 App 内置脚本：
    /// 内置脚本与当前 App 一起构建发布，行为可预期；已安装的那份只归守护进程用。
    static var scriptPath: String {
        let bundled = resource("smartroute.sh")
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return installedScript
    }

    /// 守护进程的脚本是否与 App 内置版本不一致（需要重装守护进程同步）
    static var daemonScriptOutdated: Bool {
        let bundled = resource("smartroute.sh")
        guard FileManager.default.isExecutableFile(atPath: bundled),
              FileManager.default.isExecutableFile(atPath: installedScript) else { return false }
        return !FileManager.default.contentsEqual(atPath: bundled, andPath: installedScript)
    }

    /// 配置修改一律使用内置脚本（保证支持用户级配置等新特性）
    static var configScriptPath: String {
        let bundled = resource("smartroute.sh")
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return scriptPath
    }

    static var daemonInstalled: Bool {
        FileManager.default.fileExists(atPath: daemonPlist)
            && FileManager.default.isExecutableFile(atPath: installedScript)
    }
}

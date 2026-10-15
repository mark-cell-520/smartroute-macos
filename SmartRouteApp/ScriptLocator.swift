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

    /// 优先使用已安装的脚本（与守护进程版本一致），回退到 App 内置脚本
    static var scriptPath: String {
        if FileManager.default.isExecutableFile(atPath: installedScript) {
            return installedScript
        }
        let bundled = resource("smartroute.sh")
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return installedScript
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

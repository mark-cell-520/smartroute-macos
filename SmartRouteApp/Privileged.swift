import AppKit

enum PrivilegedError: LocalizedError {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "已取消授权"
        case .failed(let message):
            return message
        }
    }
}

/// 通过 AppleScript 以管理员权限执行命令（系统会弹出密码框）
enum Privileged {
    static func run(_ command: String) throws -> String {
        // NSAppleScript 必须在主线程执行。在后台线程调它，系统密码框可能不弹、
        // 或者 App 表现成"卡住不动"（界面上转圈但什么都没发生）。
        // 这里用 main.sync 把调用搬回主线程——密码框本身就是模态对话框，
        // 主线程等用户输完密码再返回，正是正确行为。
        if Thread.isMainThread {
            return try execute(command)
        }
        return try DispatchQueue.main.sync { try execute(command) }
    }

    private static func execute(_ command: String) throws -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw PrivilegedError.failed("无法创建 AppleScript")
        }
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { throw PrivilegedError.cancelled }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "未知错误"
            throw PrivilegedError.failed(message)
        }
        return result.stringValue ?? ""
    }
}

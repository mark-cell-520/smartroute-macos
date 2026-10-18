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

    /// 执行命令并**保证失败时也能拿回完整输出**。
    ///
    /// `do shell script` 只在成功时返回 stdout；一旦退出码非 0，
    /// AppleScript 直接抛错，我们精心写的排查指引（全走 stdout）会被吞光，
    /// 用户只看到一句裸 stderr。install.sh 失败时那段"请手动执行
    /// launchctl bootstrap / log show"就是这么丢的。
    ///
    /// 做法：把输出重定向到临时日志，只把退出码打到 stdout，
    /// 再用非特权权限把日志读回来展示。
    /// - Returns: (输出内容, 退出码)
    /// 像 run 一样执行，但把 stderr 并回 stdout，并取回真实退出码。
    ///
    /// 为什么必须有这个：`do shell script` 在命令返回非零时**抛错，并且把
    /// 已经捕获到的输出一起丢掉**。而 smartroute.sh 的拒绝理由和失败诊断
    /// 几乎全写在 stderr 上——balance on 因同网关拒绝、wifi join 连不上、
    /// 脚本被另一个实例占着，等等。用裸 run 的话，调用方只能看到 AppleScript
    /// 的通用错误（"退出码 1"），脚本辛苦写好的诊断一个字都到不了用户眼前。
    ///
    /// 这个盲区让 NetworkModel 里好几处 catch 的提示变成了死代码：它们匹配
    /// "两个接口都有外网"、"另一个 smartroute 正在运行"、"连接"+"失败" 等
    /// 文本，而那些文本只在 stderr 上，永远匹配不到。看起来做了容错，
    /// 实际一次都没生效过。
    ///
    /// 和 runWithLog 的区别只在不落盘：那些命令的输出可能很长（balance on
    /// 的验证过程），写进 /tmp 再读回是白费一道；这里直接在内存里拼。
    static func runCapturing(_ command: String) throws -> (out: String, code: Int32) {
        let wrapped = "\(command) 2>&1; echo \"SR_EXIT=$?\""
        let stdout = try execute(wrapped)
        var code: Int32 = -1
        var lines = stdout.components(separatedBy: "\n")
        // 从后往前找 SR_EXIT= 标记：取退出码，并把这一行从输出里删掉
        // （不能让用户看到这个内部标记）
        for i in lines.indices.reversed() {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("SR_EXIT=") {
                code = Int32(t.dropFirst("SR_EXIT=".count)) ?? -1
                lines.remove(at: i)
                break
            }
        }
        let out = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out, code)
    }

    static func runWithLog(_ command: String, logFile: String) throws -> (out: String, code: Int32) {
        let wrapped = "\(command) > '\(logFile)' 2>&1; echo \"SR_EXIT=$?\""
        let stdout = try run(wrapped)
        // 最后一行是 SR_EXIT=<码>，前面是 wrapped 命令本身的 echo（没有）
        var code: Int32 = -1
        let lines = stdout.components(separatedBy: "\n")
        for line in lines.reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("SR_EXIT=") {
                code = Int32(t.dropFirst("SR_EXIT=".count)) ?? -1
                break
            }
        }
        // 读回日志。文件由 root 经 do shell script 创建，umask 022 → 0644，
        // 普通用户读得到。读不到也不致命，退回 stdout。
        var out = ""
        if let data = FileManager.default.contents(atPath: logFile),
           let text = String(data: data, encoding: .utf8) {
            out = text
        }
        if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out = stdout
        }
        return (out, code)
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

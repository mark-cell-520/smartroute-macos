import Foundation

/// 同步执行 shell 命令，带超时保护
enum Shell {
    /// - Returns: (输出(stdout+stderr), 退出码)
    static func run(_ command: String, timeout: TimeInterval = 20) -> (out: String, code: Int32) {
        let task = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.standardInput = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return ("启动失败: \(error.localizedDescription)", -1)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            usleep(100_000)
        }
        var timedOut = false
        if task.isRunning {
            timedOut = true
            task.terminate()
            usleep(300_000)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        var out = String(decoding: outData, as: UTF8.self)
        let err = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty {
            out += (out.isEmpty ? "" : "\n") + err
        }
        if timedOut {
            out += "\n(命令超时 \(Int(timeout)) 秒)"
        }
        return (out, task.terminationStatus)
    }
}

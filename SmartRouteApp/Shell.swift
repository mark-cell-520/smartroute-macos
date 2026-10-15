import Foundation

/// 同步执行 shell 命令，带超时保护
///
/// 超时处理必须"先杀、再等到真正退出"：Process 析构时如果子进程还活着，
/// Foundation 会在 -[NSConcreteTask dealloc] 里抛异常，直接让 App 崩掉
/// （objc_exception_throw → SIGABRT）。历史上这里只 terminate 后睡 300ms，
/// 遇到慢命令（如 balance status 里的延迟测量）就会崩。
enum Shell {
    /// 把任意字符串包成可安全放进 shell 命令的单引号字面量。
    /// Wi-Fi 名里出现空格、单引号、$ 都很常见，不转义会直接被 shell 拆开或求值。
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

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

        // 并发读管道：输出超过管道缓冲区（64KB）时子进程会写阻塞，
        // 必须一边等一边读，否则双方互相等、死锁。
        var outData = Data()
        var errData = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        readGroup.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        // 等进程退出（带超时）。超时：terminate → 等 2 秒 → SIGKILL → 再等。
        // 无论如何都要等到它真正退出，否则析构即崩溃。
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            task.waitUntilExit()
            exited.signal()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            task.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(task.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        _ = readGroup.wait(timeout: .now() + 2)

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

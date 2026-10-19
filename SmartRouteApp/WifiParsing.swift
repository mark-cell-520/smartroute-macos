import Foundation

/// Wi-Fi 相关输出的解析
///
/// 这些函数是纯函数（输入字符串 → 输出值），单独放一个文件是为了能编译进
/// 测试二进制里直接验证。历史上解析逻辑混在 NetworkModel 里，结果
/// `String(t[r])` 拿到的是整个正则匹配而不是捕获组，用户点连接时
/// 真的把 "1. CZ-305"（带序号前缀）当成 SSID 发给了 networksetup。
///
/// 教训：**凡是"从脚本输出里抠字段"的代码，都必须拿真实输出验证过**，
/// 不能凭"正则看起来对"就认为对。见 tests/mock_wifi_parse.sh。
enum WifiParsing {

    /// 解析 `smartroute wifi list --raw` 的输出：一行一个 SSID，原样返回。
    /// 不用带序号的格式——SSID 本身可以叫 "1. CZ-305"，按 "数字. " 剥前缀会剥错。
    static func savedNetworks(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 解析 `smartroute wifi current` 的输出。两种格式都认：
    ///   人看的："Wi-Fi en1  信号 -70 dBm（2/4 格）  信道 44"
    ///   机器的："rssi=-70 channel=44 rate=432 noise=-97"（--raw，一次调用拿全）
    /// App 用 --raw：system_profiler 一次要约 1.7 秒，能少调一次就少调一次。
    static func currentSignal(_ text: String) -> (rssi: String, channel: String, bars: Int)? {
        // 先试 key=value 格式（更规整，也不会和中文文案耦合）
        if let rssi = capture(text, pattern: "rssi=(-?[0-9]+)") {
            let channel = capture(text, pattern: "channel=([0-9]+)") ?? "?"
            return (rssi: rssi, channel: channel, bars: bars(for: rssi))
        }
        // 再试人类格式
        let rssi = capture(text, pattern: "信号\\s+(-?[0-9]+)\\s+dBm")
        let channel = capture(text, pattern: "信道\\s+([0-9]+)")
        let bars = capture(text, pattern: "（([0-9]+)/4\\s*格）")
        guard let r = rssi else { return nil }
        return (rssi: r,
                channel: channel ?? "?",
                bars: bars.flatMap(Int.init) ?? 0)
    }

    /// dBm -> 格数（0~4）。**必须和脚本里的 wifi_bars 逐档对齐**，
    /// 否则同一个信号在命令行显示 4 格、App 里显示 3 格。
    /// 有测试专门比对两边（mock_wifi_parse.sh 的"格数与脚本一致"）。
    static func bars(for rssi: String) -> Int {
        guard let v = Int(rssi) else { return 0 }
        // 注意区间方向：必须小的在左（-59...-40）。写成 -40...(-59) 是从大到小，
        // 编译能过但一运行就 trap（SIGTRAP）——App 走 --raw 格式就会崩。
        switch v {
        case -59...(-40): return 4   // 脚本 -5*|-4*
        case -69...(-60): return 3   // 脚本 -6*
        case -79...(-70): return 2   // 脚本 -7*
        default: return 1            // 其余（含 -80 以外）
        }
    }

    /// 附近网络的一条记录
    struct Nearby: Identifiable, Equatable {
        // 身份用 SSID 而不是 UUID()：每次扫描重建数组都是全新 UUID，
        // ForEach 就没法做行复用/差分，每次刷新整块重建。
        // 一次扫描里 SSID 不会重复，用它当 id 是稳定的。
        var id: String { name }
        var name: String
        var rssi: Int
        var bars: Int
        var channel: String
    }

    /// 解析 `smartroute wifi scan` 输出里「在范围的」那一段。
    ///
    /// 只取到空行或下一个标题为止——后面的「确认不在范围」「未能确认」
    /// 是另一类信息，混进来会把不在范围的网络也显示成能连。
    ///
    /// 每行形如："  CZ-305    -52 dBm（4/4 格）  信道 6"
    /// SSID 可能带空格（如 "A9 5G"），所以名字取到第一个空白为止，
    /// 而不是按空白切分整行。
    static func nearbyNetworks(_ text: String) -> [Nearby] {
        var out: [Nearby] = []
        var inRange = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("在范围的") { inRange = true; continue }
            // 段落结束：空行，或下一个标题
            if inRange && (t.isEmpty || t.hasPrefix("确认不在") || t.hasPrefix("有 ")) { break }
            guard inRange, !t.isEmpty else { continue }
            guard let name = capture(t, pattern: "^([^[:space:]]+)"),
                  let rssi = capture(t, pattern: "(-?[0-9]+)[[:space:]]+dBm"),
                  let bars = capture(t, pattern: "（([0-9]+)/4") else { continue }
            out.append(Nearby(name: name,
                              rssi: Int(rssi) ?? 0,
                              bars: Int(bars) ?? 0,
                              channel: capture(t, pattern: "信道[[:space:]]+([0-9]+)") ?? "?"))
        }
        return out
    }

    /// 从 scan 输出里取「有 N 个未能确认」的 N（没有则 nil）
    ///
    /// ⚠️ 原来的正则是 `有\s+(\d+)\s+个没能确认`，要求"个"紧跟"没能确认"。
    /// 但脚本实际打印的是
    ///     （有 8 个已保存网络没能确认在不在范围——系统扫描有冷却，不是故障…）
    /// 中间多了"已保存网络"四个字，于是**永不匹配**——快速扫描下 8/10 个
    /// 网络没确认是常态，用户却看不到这句提示，会以为全查过了。
    /// 这就是"脚本输出格式变了但解析没跟上"那一类，而且方向是往少了说。
    ///
    /// 现在两种格式都认：脚本侧的提示（带"已保存网络"）和 wifi_nearby 的
    /// `@unknown N` 契约行。后者更稳——不依赖中文文案的措辞。
    static func scanUnknownCount(_ text: String) -> Int? {
        if let n = capture(text, pattern: "有[[:space:]]+([0-9]+)[[:space:]]+个(?:已保存网络)?没能确认") {
            return Int(n)
        }
        // @unknown N 是 wifi_nearby 的机器可读契约，优先于中文文案
        if let n = capture(text, pattern: "@unknown[[:space:]]+([0-9]+)") {
            return Int(n)
        }
        return nil
    }

    /// 取第一个捕获组。注意：`String.range(of:options:.regularExpression)`
    /// 返回的是**整个匹配**的范围，不是捕获组的——直接 String(x[r]) 会把
    /// "信号 -70 dBm" 整段当成值。必须用 NSRegularExpression 的 range(at: 1)。
    static func capture(_ text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: text, range: full) else { return nil }
        guard m.numberOfRanges > 1 else { return nil }
        let g = m.range(at: 1)
        guard g.location != NSNotFound, let r = Range(g, in: text) else { return nil }
        return String(text[r])
    }
}

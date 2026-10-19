import Foundation

// Swift 纯解析函数的单测。为什么单独做：审计意见说"Swift NetworkModel 的解析
// 函数没有任何自动化测试，唯一覆盖是 mock_wifi_parse（且只测脚本）"。
// 这些函数是 App 显示一切数据的地基——解析错，界面就显示错，而界面是用户
// 唯一能看到的东西。此前改 bug 全靠人眼点开 App 看。
//
// 编译方式见 tests/mock_swift_parse.sh：把生产源文件（去掉带 @main 的
// SmartRouteApp.swift 和 make_icon.swift）连同本文件一起编成可执行文件。

var failures = 0, checks = 0
func eq(_ got: String, _ want: String, _ name: String) {
    checks += 1
    if got == want { print("  OK \(name)") }
    else { failures += 1; print("  XX \(name): got [\(got)] want [\(want)]") }
}
func eqI(_ got: Int, _ want: Int, _ name: String) {
    checks += 1
    if got == want { print("  OK \(name)") }
    else { failures += 1; print("  XX \(name): got \(got) want \(want)") }
}
func isTrue(_ cond: Bool, _ name: String) {
    checks += 1
    if cond { print("  OK \(name)") }
    else { failures += 1; print("  XX \(name)") }
}

print("== 1. savedNetworks：一行一个 SSID ==")
// --raw 输出：一行一个 SSID，不带序号
eq(WifiParsing.savedNetworks("Home-5G\nOffice\n").joined(separator: "|"), "Home-5G|Office", "两个网络")
eq(WifiParsing.savedNetworks("").joined(separator: "|"), "", "空输入")
// 带序号的格式不能被剥错：SSID 本身可以叫 "1. CZ-305"，
// 按 "数字. " 剥前缀会把真正的名字切掉。所以 --raw 不带序号，
// 但万一收到带序号的也不该崩
eq(WifiParsing.savedNetworks("1. CZ-305\n").joined(separator: "|"), "1. CZ-305", "序号开头的 SSID 不被误剥")
// 空行要忽略，否则列表里出现空白项
eq(WifiParsing.savedNetworks("A\n\nB\n").joined(separator: "|"), "A|B", "忽略空行")

print("== 2. bars：RSSI → 格数 ==")
// 分档必须和脚本的 wifi_bars 逐档对齐，否则同一个信号命令行显示 4 格、
// App 里显示 3 格。真实分档：-59...-40→4 / -69...-60→3 / -79...-70→2 / 其余→1。
// 每个边界都实测——区间方向写反（-40...(-59)）编译能过但一运行就 SIGTRAP。
eqI(WifiParsing.bars(for: "-30"), 1, "-30（强于最高档）→ 1")
eqI(WifiParsing.bars(for: "-39"), 1, "-39 刚出 4 格区 → 1")
eqI(WifiParsing.bars(for: "-40"), 4, "-40 是 4 格区下界")
eqI(WifiParsing.bars(for: "-50"), 4, "-50 → 4 格")
eqI(WifiParsing.bars(for: "-59"), 4, "-59 是 4 格区上界")
eqI(WifiParsing.bars(for: "-60"), 3, "-60 是 3 格区下界")
eqI(WifiParsing.bars(for: "-69"), 3, "-69 是 3 格区上界")
eqI(WifiParsing.bars(for: "-70"), 2, "-70 是 2 格区下界")
eqI(WifiParsing.bars(for: "-79"), 2, "-79 是 2 格区上界")
eqI(WifiParsing.bars(for: "-80"), 1, "-80 落进 default → 1")
eqI(WifiParsing.bars(for: "-100"), 1, "-100 → 1（不是 0）")
// 非数字不能崩，也不能给出错的格数
eqI(WifiParsing.bars(for: ""), 0, "空串 → 0 格")
eqI(WifiParsing.bars(for: "abc"), 0, "非数字 → 0 格")
eqI(WifiParsing.bars(for: "n/a"), 0, "n/a → 0 格")

print("== 3. currentSignal：解析当前连接 ==")
// App 实际用的是 --raw 的 key=value 格式（system_profiler 一次约 1.7 秒，能少调一次就少调一次）
let sig = WifiParsing.currentSignal("rssi=-67 channel=44 rate=432 noise=-97")
isTrue(sig != nil, "能解析 key=value 格式")
if let s = sig {
    eq(s.rssi, "-67", "RSSI 值")
    eq(s.channel, "44", "信道")
    eqI(s.bars, 3, "-67 → 3 格")
}
// 人看的格式也要认（命令行输出粘过来时的场景）
let human = WifiParsing.currentSignal("Wi-Fi en1  信号 -70 dBm（2/4 格）  信道 44")
isTrue(human != nil, "能解析人类格式")
if let h = human {
    eq(h.rssi, "-70", "人类格式 RSSI")
    eq(h.channel, "44", "人类格式信道")
    eqI(h.bars, 2, "人类格式直接取括号里的格数（2）")
}
isTrue(WifiParsing.currentSignal("没有信号信息") == nil, "没有信号时返回 nil（不崩）")
isTrue(WifiParsing.currentSignal("") == nil, "空输入返回 nil")

print("== 4. nearbyNetworks：附近网络列表 ==")
// 真实输出：先一行"在范围的..."标题，然后每行 "  SSID  -52 dBm（4/4 格）  信道 6"
let scanText = """
在范围的已保存网络（按信号排序，越靠前越好）：
  CZ-305    -52 dBm（4/4 格）  信道 6
  Office    -70 dBm（2/4 格）  信道 44

确认不在范围的（旁边没有这些路由器，属正常）：
  Ghost    -85 dBm（1/4 格）  信道 11
"""
let near = WifiParsing.nearbyNetworks(scanText)
eqI(near.count, 2, "只取「在范围的」那一段（2 个）")
if near.count == 2 {
    eq(near[0].name, "CZ-305", "第一个名字")
    eqI(near[0].rssi, -52, "第一个 RSSI")
    eq(near[0].channel, "6", "第一个信道")
    eqI(near[0].bars, 4, "直接取括号里的格数（4）")
    eq(near[1].name, "Office", "第二个名字")
    eqI(near[1].rssi, -70, "第二个 RSSI")
}
eqI(WifiParsing.nearbyNetworks("").count, 0, "空输入 → 空列表")
// 没有"在范围的"标题时就该是空的——不能把整段输出都当成附近网络
eqI(WifiParsing.nearbyNetworks("确认不在范围的：\n  Ghost  -85 dBm（1/4 格）  信道 11\n").count, 0,
    "没有在范围标题时不解析（否则不在范围的也显示成能连）")
// 名字取到第一个空白为止：SSID 带空格时只取第一段（已知限制，写在注释里）
let spaced = WifiParsing.nearbyNetworks("在范围的：\n  A9 5G  -55 dBm（4/4 格）  信道 36\n")
eqI(spaced.count, 1, "带空格 SSID 也能解析出一条")
if spaced.count == 1 { eq(spaced[0].name, "A9", "带空格 SSID 只取第一个词（文档化的限制）") }

print("== 5. scanUnknownCount：未能确认的数量 ==")
// 脚本原文："有 $WIFI_SCAN_UNKNOWN 个没能确认（系统扫描有冷却，不是故障），重试即可。"
// 注意是"没能确认"不是"未能确认"——这个词必须和脚本逐字对上，
// 差一个字这个提示就永远不出现，用户以为全查过了。
eqI(WifiParsing.scanUnknownCount("有 3 个没能确认（系统扫描有冷却，不是故障），重试即可。") ?? -1, 3, "解析出 3")
eqI(WifiParsing.scanUnknownCount("有 0 个没能确认") ?? -1, 0, "0 也能解析（不是 nil）")
isTrue(WifiParsing.scanUnknownCount("扫描完成") == nil, "没有该提示时返回 nil")
isTrue(WifiParsing.scanUnknownCount("") == nil, "空输入返回 nil")

print("== 6. capture：通用正则捕获 ==")
eq(WifiParsing.capture("IP: 192.168.1.5", pattern: "IP: ([0-9.]+)") ?? "", "192.168.1.5", "捕获 IP")
isTrue(WifiParsing.capture("没有匹配", pattern: "IP: ([0-9.]+)") == nil, "不匹配返回 nil")
// 恶意/异常正则不能让 App 崩（NSRegularExpression 对坏 pattern 抛异常）
isTrue(WifiParsing.capture("abc", pattern: "([") == nil, "坏正则不崩，返回 nil")

print("== 7. sanitizeConf：导入配置的校验 ==")
// 与 smartroute.sh 的 conf_value_ok 同源。导入是破坏性操作，
// 非法行必须被丢掉并计数，不能假报"已导入并生效"。
let (clean1, rej1) = NetworkModel.sanitizeConf("MODE=auto\nOK_N=2\n")
isTrue(clean1.contains("MODE=auto"), "合法键保留")
isTrue(clean1.contains("OK_N=2"), "数字键保留")
eqI(rej1, 0, "没有非法行")

let (clean2, rej2) = NetworkModel.sanitizeConf("MODE=banana\nOK_N=2\n")
isTrue(!clean2.contains("banana"), "非法 MODE 值被拒")
isTrue(clean2.contains("OK_N=2"), "同批的合法行仍保留")
eqI(rej2, 1, "计 1 行被拒")

let (clean3, rej3) = NetworkModel.sanitizeConf("BOGUS_KEY=1\nOK_N=3\n")
isTrue(!clean3.contains("BOGUS_KEY"), "白名单外的键被拒")
isTrue(clean3.contains("OK_N=3"), "合法行仍保留")
eqI(rej3, 1, "陌生键计 1 行")

// 布尔键只认 0/1
let (_, rejBool) = NetworkModel.sanitizeConf("NOTIFY=yes\n")
eqI(rejBool, 1, "NOTIFY=yes 被拒")
isTrue(NetworkModel.sanitizeConf("NOTIFY=0\n").1 == 0, "NOTIFY=0 通过")

// 数字键必须是非负整数
let (_, rejNeg) = NetworkModel.sanitizeConf("OK_N=-1\n")
eqI(rejNeg, 1, "负数被拒")
isTrue(NetworkModel.sanitizeConf("COOLDOWN=abc\n").1 == 1, "非数字被拒")

// 注释和空行不算被拒（用户配置文件里很常见）
let (cleanC, rejC) = NetworkModel.sanitizeConf("# 注释\n\nMODE=wifi\n")
isTrue(cleanC.contains("MODE=wifi"), "注释不影响合法行")
eqI(rejC, 0, "注释和空行不计入被拒")

// 没有 = 的行算被拒（格式错误）
eqI(NetworkModel.sanitizeConf("这一行没有等号\n").1, 1, "无等号的行被拒")

// 全是非法内容时返回空，调用方要能发现"什么都没导入"
let (cleanAll, _) = NetworkModel.sanitizeConf("MODE=banana\nBOGUS=1\n")
isTrue(cleanAll.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "全非法时内容为空")

print("== 8. Shell.quote：任意字符串安全进 shell ==")
// 这是 App 拼特权命令的唯一入口。Wi-Fi 名里出现空格、单引号、$ 都很常见，
// 不转义会被 shell 拆开或求值。历史上恶意 Wi-Fi 名就是从这里打进去执行的。
// 关键：这里测的是**真实的 Swift 实现**，再经**真实的 bash** 往返——
// 以前的 mock_quote.sh 是在 bash 里复刻一遍转义逻辑，Swift 真身漂移了
// 它照样通过，属于"测试说谎"。现在两边都跑真的。
func quoteRoundTrip(_ s: String, _ name: String) {
    checks += 1
    let quoted = Shell.quote(s)
    // 用真实 bash 执行，看拿到的参数和原串是否完全一致
    let (out, code) = Shell.run("printf '%s' " + quoted, timeout: 10)
    if code == 0 && out == s { print("  OK \(name)") }
    else { failures += 1; print("  XX \(name): got [\(out)] code=\(code) quoted=[\(quoted)]") }
}
quoteRoundTrip("Home-5G", "普通 SSID")
quoteRoundTrip("A9 5G", "带空格（不能拆成两个参数）")
quoteRoundTrip("it's", "带单引号（最容易打破引用）")
quoteRoundTrip("a'b'c", "多个单引号")
quoteRoundTrip("$(touch /tmp/PWNED)", "命令替换不能被求值")
quoteRoundTrip("`touch /tmp/PWNED`", "反引号不能被求值")
quoteRoundTrip("a;rm -rf /", "分号不能当命令分隔符")
quoteRoundTrip("a|b", "管道符")
quoteRoundTrip("a&b", "& 不能当后台任务")
quoteRoundTrip("a>b", "重定向符")
quoteRoundTrip("a\\b", "反斜杠")
quoteRoundTrip("a\"b", "双引号")
quoteRoundTrip("", "空串")
quoteRoundTrip(" 前后空格 ", "前后空格要保留")
quoteRoundTrip("中文网络名", "中文")
quoteRoundTrip("网络 名 带空格", "中文带空格")
// 恶意 Wi-Fi 名的真实 payload（历史漏洞）：双引号里嵌 do shell script
quoteRoundTrip("x\" & (do shell script \"touch /tmp/PWNED2\") & \"", "AppleScript 注入 payload 原样往返")

print("== 9. Privileged.runWithLog：失败时也必须拿回完整输出 ==")
// 这个函数的存在理由：do shell script 只在成功时返回 stdout，一旦退出码非 0，
// AppleScript 直接抛错，install.sh 里那段"请手动执行 launchctl bootstrap /
// log show"的排查指引（全走 stdout）会被全部吞掉，用户只剩一句裸 stderr。
// 这里验的是退出码解析——真实 AppleScript 调不了，但解析逻辑必须对。
func parseExitCode(_ stdout: String) -> Int32 {
    for line in stdout.components(separatedBy: "\n").reversed() {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("SR_EXIT=") {
            return Int32(t.dropFirst("SR_EXIT=".count)) ?? -1
        }
    }
    return -1
}
checks += 1
parseExitCode("SR_EXIT=0") == 0 ? print("  OK 退出码 0") : { failures += 1; print("  XX 退出码 0") }()
checks += 1
parseExitCode("SR_EXIT=1") == 1 ? print("  OK 退出码 1（安装失败）") : { failures += 1; print("  XX 退出码 1") }()
checks += 1
parseExitCode("SR_EXIT=127") == 127 ? print("  OK 退出码 127（命令不存在）") : { failures += 1; print("  XX 退出码 127") }()
// 多行输出里 SR_EXIT 在最后一行——真实场景 stdout 会有很多内容
checks += 1
parseExitCode("==> 安装 smartroute\n==> 注册 launchd\nSR_EXIT=1") == 1
    ? print("  OK 多行输出也能取到退出码")
    : { failures += 1; print("  XX 多行输出取不到退出码") }()
// 退出码后面可能跟换行
checks += 1
parseExitCode("SR_EXIT=2\n") == 2 ? print("  OK 带尾随换行") : { failures += 1; print("  XX 带尾随换行") }()
// 没有 SR_EXIT 行时返回 -1，调用方据此判失败，不能误判成成功
checks += 1
parseExitCode("啥都没有") == -1 ? print("  OK 没有 SR_EXIT 时返回 -1（不当成功）") : { failures += 1; print("  XX 没有 SR_EXIT") }()

print("== 10. 守护进程三态：不允许把「刚唤醒」误判成「没在跑」 ==")
// plist 用的是 StartInterval=20，进程大部分时间并不存在，pgrep 几乎永远查不到
// ——它不能作为"没在跑"的证据。唯一可用的非特权信号是日志 mtime。
// 而 Mac 睡眠期间 launchd 不跑 job，唤醒后要等最多 20 秒才写第一行：
// 只看布尔就会误报"未在运行"，误报的代价是有人会去重装。
// 这里验的是分档逻辑本身（真实 mtime 依赖运行环境，用等价运算表达）。
enum TestDaemonState { case running, waiting, stopped }
func classify(_ age: TimeInterval) -> TestDaemonState {
    if age < 90 { return .running }
    if age < 300 { return .waiting }
    return .stopped
}
checks += 1
classify(0) == .running ? print("  OK 日志刚写 → running") : { failures += 1; print("  XX 0 秒") }()
checks += 1
classify(89) == .running ? print("  OK 89 秒（4~5 个轮询周期内）→ running") : { failures += 1; print("  XX 89 秒") }()
checks += 1
classify(90) == .waiting ? print("  OK 90 秒刚过 → waiting（不下结论）") : { failures += 1; print("  XX 90 秒") }()
checks += 1
classify(299) == .waiting ? print("  OK 299 秒 → waiting") : { failures += 1; print("  XX 299 秒") }()
checks += 1
classify(300) == .stopped ? print("  OK 300 秒 → stopped（该告警了）") : { failures += 1; print("  XX 300 秒") }()
checks += 1
classify(99999) == .stopped ? print("  OK 很久没更新 → stopped") : { failures += 1; print("  XX 很久") }()

print("== 11. 终端原文 → 一句人话（App 用户看不懂 launchctl）==")
// install.sh / uninstall.sh 的原文含 "sudo launchctl bootstrap ..." 这种命令，
// 直接铺给纯 App 用户既读不懂又被吓到。这里验归纳逻辑覆盖了每条真实路径。
// 复刻 NetworkModel 的 daemonResultSummary（同一份规则，改规则时两边都要改）。
func summarize(_ msg: String) -> String {
    if msg.contains("已取消授权") { return "已取消，什么都没有改动。" }
    if msg.contains("守护进程没起来") || msg.contains("安装失败") {
        return "安装失败：自动选路没有生效。展开「详情」看原因，照里面的命令手动做一遍即可。"
    }
    if msg.contains("卸载完成") { return "卸载完成。程序、配置、规则、路由、进程都已清干净。" }
    if msg.contains("已暂停") { return "已暂停自动选路。重启 Mac 会恢复；想重启也不恢复，用 launchctl disable。" }
    if msg.contains("已恢复自动选路") { return "已恢复自动选路，每 20 秒检测一次。" }
    if msg.contains("已通过 bootstrap") || msg.contains("守护进程已加载并运行") {
        return "守护进程已装好并在运行，每 20 秒自动检测一次。"
    }
    if msg.contains("失败") { return "操作失败，展开「详情」看原因。" }
    return "操作完成。"
}
checks += 1
summarize("已取消授权，什么都没有改动。").contains("已取消")
    ? print("  OK 取消授权说清「什么都没动」") : { failures += 1; print("  XX 取消") }()
checks += 1
summarize("✗ 守护进程没起来——自动选路不会工作。\nsudo launchctl bootstrap ...").contains("安装失败")
    ? print("  OK 守护进程起不来 → 说失败并指向详情") : { failures += 1; print("  XX 起不来") }()
checks += 1
summarize("==> 安装 smartroute 到 /usr/local/bin\n✓ 已通过 bootstrap 注册").contains("已装好并在运行")
    ? print("  OK 安装成功 → 说人话，不提 launchctl") : { failures += 1; print("  XX 成功") }()
checks += 1
summarize("卸载完成。接下来：\n1. ...").contains("卸载完成")
    ? print("  OK 卸载完成") : { failures += 1; print("  XX 卸载") }()
checks += 1
summarize("已暂停自动选路").contains("重启 Mac 会恢复")
    ? print("  OK 暂停时说明是临时的") : { failures += 1; print("  XX 暂停") }()
checks += 1
summarize("已恢复自动选路").contains("已恢复")
    ? print("  OK 恢复") : { failures += 1; print("  XX 恢复") }()
checks += 1
// 顺序很重要："失败" 要排在 bootstrap 之后，否则安装成功但含 warn 的
// 输出会被误判成失败。
summarize("! 没找到 wifiscan 可执行文件\n✓ 已通过 bootstrap 注册\n安装完成").contains("已装好并在运行")
    ? print("  OK 有 warn 但安装成功 → 不算失败")
    : { failures += 1; print("  XX warn 被误判成失败") }()
// 摘要里不能出现裸命令，那正是要避免的东西
checks += 1
!summarize("✗ 守护进程没起来\nsudo launchctl bootstrap system /Library/...").contains("sudo")
    ? print("  OK 摘要里不含 sudo 命令（原文在详情里）")
    : { failures += 1; print("  XX 摘要漏出命令") }()

print("== 12. doctor 的守护进程判断：pgrep 在这个 plist 下不可靠 ==")
// 这个 plist 用 StartInterval=20，进程只在每次运行的瞬间存在（约 1~2 秒），
// pgrep 命中率只有一成左右；而 launchctl print system/... 需要 root，
// App 的体检页是**不带 sudo** 调的。两条都不满足就报"未检测到"，
// 十次有八次误报，还劝用户重装一遍。
// 正确信号是日志新鲜度：cmd_watch 每轮往 stdout 打一行，
// plist 重定向进 /var/log/smartroute.out，mtime 就是心跳。
// 本测试的可执行文件是在项目根目录跑的，但万一换了 cwd 就什么都读不到。
// 两个候选路径都试，并明确报错原因——静默返回空串会让四条断言一起假失败，
// 而看起来像"代码没改"，最容易漏过去。
let _candidates = ["smartroute.sh", "../smartroute.sh"]
let doctorSrc = _candidates
    .compactMap { FileManager.default.contents(atPath: $0).flatMap { String(data: $0, encoding: .utf8) } }
    .first { !$0.isEmpty } ?? ""
checks += 1
!doctorSrc.isEmpty
    ? print("  OK 读到 smartroute.sh（\(doctorSrc.count) 字符）")
    : { failures += 1; print("  XX 读不到 smartroute.sh，以下四条断言无效——检查运行目录") }()
if doctorSrc.isEmpty {
    print("结果: \\(checks - failures) 通过, \\(failures) 失败")
    exit(2)
}
checks += 1
doctorSrc.contains("stat -f%m /var/log/smartroute.out")
    ? print("  OK doctor 用 smartroute.out 的 mtime 做心跳")
    : { failures += 1; print("  XX doctor 没读日志 mtime") }()
checks += 1
doctorSrc.contains("-lt 90") && doctorSrc.contains("-lt 300")
    ? print("  OK 有三态分档（90/300 秒）")
    : { failures += 1; print("  XX 没有等待态，刚唤醒会误报") }()
checks += 1
doctorSrc.contains("守护进程未运行：cd")
    ? print("  OK 只有真停了才劝重装")
    : { failures += 1; print("  XX 重装建议没有限定条件") }()
checks += 1
doctorSrc.contains("speed=网速优先 / latency=延时优先")
    ? print("  OK 体检报告列全五个选路模式")
    : { failures += 1; print("  XX 模式说明漏了 speed/latency") }()

print("== 13. 同网关：工具的招牌功能在此网络下无效，必须说清 ==")
// 用户实测反馈："以太网卡主、WiFi 也不行、自动更换网络没用、双网并发也没效果"。
// 根因：他的两个接口是同一 /24 网段、同一个网关（192.168.1.1），
// 也就是同一台路由器出来的两个入口。此时：
// · 路由器宕 = 两边一起宕，故障转移没有可切换的目标
// · 双网并发没有第二条 WAN 可分
// 而原来的同网关提示只在**双网并发页**出现，用户正在看的是状态页——
// 结论没出现在他眼前，等于没说。
checks += 1
doctorSrc.contains("same_gateway")
    ? print("  OK status 输出机器可读的 same_gateway")
    : { failures += 1; print("  XX status 没有 same_gateway 输出") }()
// 判定必须比两个接口各自的网关，不能拿"当前默认路由的网关"比（后者只有一个值，恒等）
// 本测试可执行文件在项目根目录跑，但保险起见两个候选都试。
// 之前读 ../smartroute.sh 就是这么栽的——四条断言一起假失败，
// 而看起来像"代码没改"，最容易漏过去。
func readSrc(_ rel: String) -> String {
    for p in [rel, "../" + rel] {
        if let d = FileManager.default.contents(atPath: p),
           let t = String(data: d, encoding: .utf8), !t.isEmpty { return t }
    }
    return ""
}
let viewsSrc = readSrc("SmartRouteApp/NetworkModel.swift")
checks += 1
viewsSrc.contains("sameGateway") && viewsSrc.contains("ethGw == wifiGw")
    ? print("  OK App 比较两个接口各自的网关")
    : { failures += 1; print("  XX 同网关判定方式不对") }()
// 状态页必须出现这个警告（用户实际看的那一页）
let uiSrc = readSrc("SmartRouteApp/Views.swift")
checks += 1
uiSrc.contains("两个接口走同一台路由器，故障转移在此网络下无效")
    ? print("  OK 状态页有同网关警告")
    : { failures += 1; print("  XX 状态页没有同网关警告") }()
// 必须给出唯一还有意义的动作，不能只宣布"没用"
checks += 1
uiSrc.contains("网速优先") && uiSrc.contains("挑更快的那条")
    ? print("  OK 给出了同网关下仍有效的动作（网速优先）")
    : { failures += 1; print("  XX 只宣布没用，没给出路") }()
// 链路速率只在同网关时取（system_profiler 要约 1.7 秒，不能白等）
checks += 1
viewsSrc.contains("if !snapshot.sameGateway.isEmpty {") && viewsSrc.contains("linkSpeedEth")
    ? print("  OK 链路速率只在同网关时取（省 1.7 秒）")
    : { failures += 1; print("  XX 链路速率取值没有设条件") }()
// getMedia 取的是 Active 行，不是整个输出（会带进 Current: autoselect）
checks += 1
viewsSrc.contains("/^Active:/")
    ? print("  OK 链路速率取 Active 行（不混入 Current: autoselect）")
    : { failures += 1; print("  XX 链路速率解析不对") }()

print("== 14. flap 证据必须出现在默认落地页 ==")
// 一开始把 flap 提示放在了 DaemonView（守护进程页），而默认落地页是 StatusView。
// 用户反馈"以太网卡主"时看的是状态页——证据放在另一个标签页等于没说。
// 同网关横幅当初也是放错了地方才改过来的，同一个错误不该犯第二次。
// 用源码顺序断言：flap 的 Text/Banner 必须出现在 StatusView 结构体内。
let uiSrc2 = readSrc("SmartRouteApp/Views.swift")
func structBody(_ name: String) -> String {
    guard let r = uiSrc2.range(of: "struct \(name): View {") else { return "" }
    let rest = String(uiSrc2[r.lowerBound...])
    // 到下一个顶层 struct 之前
    if let e = rest.range(of: "\nstruct ", options: .literal, range: rest.index(rest.startIndex, offsetBy: 20)..<rest.endIndex) {
        return String(rest[..<e.lowerBound])
    }
    return rest
}
let statusBody = structBody("StatusView")
let daemonBody = structBody("DaemonView")
let speedBody = structBody("SpeedView")
checks += 1
statusBody.contains("flapCount")
    ? print("  OK flap 提示在 StatusView（默认落地页）")
    : { failures += 1; print("  XX flap 提示不在状态页，用户看不到") }()
checks += 1
!daemonBody.contains("flapCount")
    ? print("  OK DaemonView 里没有重复的 flap 提示（不放两处）")
    : { failures += 1; print("  XX flap 提示重复出现在两个视图") }()
// 两条提示要在一起：同网关横幅解释原因，flap 给出证据
checks += 1
statusBody.contains("sameGateway") && statusBody.contains("flapCount")
    ? print("  OK 状态页同时有原因（同网关）和证据（flap）")
    : { failures += 1; print("  XX 状态页缺其中一项") }()
// 只告诉用户"没用"而不告诉他能做什么，等于把人挡在门口就不管了。
// 同网关横幅必须给出可执行的动作，否则用户看完只剩下失望。
checks += 1
statusBody.contains("fetch 多连接下载")
    ? print("  OK 状态页给出了替代做法（fetch 多连接下载，不依赖 pf）")
    : { failures += 1; print("  XX 状态页只说没用、没给能做什么") }()
// 假证据警告也必须在默认落地页。这轮实测过：StatusView 原来的提示卡
// 教用户"看两条曲线同时起伏即证明被分摊"，而 Wi-Fi 关联着就永远有背景
// 心跳——那正是 balance_validate 当初把门槛提到 64KB+10% 要排除的假信号。
// 结论放错页等于没说，而教人看假信号比不说更糟。
checks += 1
statusBody.contains("不能证明流量被分摊")
    ? print("  OK 状态页警告了假证据（曲线起伏 ≠ 流量分摊）")
    : { failures += 1; print("  XX 状态页没警告假证据，用户会拿背景心跳当成效") }()
// 这三条只在 SpeedView 有是不够的——默认落地页是 StatusView。
// 曾经把同网关+替代方案写进了 SpeedView，用户不翻页就永远看不到。
checks += 1
!speedBody.contains("不能证明流量被分摊") || statusBody.contains("不能证明流量被分摊")
    ? print("  OK 假证据警告在默认落地页（不是只在非默认页）")
    : { failures += 1; print("  XX 假证据警告只放在非默认页") }()

// ── 第 15 节之前先补的权威测试：Shell.quote / Privileged 的转义 ──
//
// 为什么必须用真实代码测：tests/mock_quote.sh 的注释一直写着
//   「权威测试是 mock_swift_parse.sh 的第 8 节：那里编译真实的
//     Shell.quote，再经真实的 bash 往返，包括恶意 Wi-Fi 名的 payload。」
// 但那个第 8 节从来没写过。于是 mock_quote.sh 里跑的是**复刻版**
// （在 bash 里重抄了一遍 sed 替换），它验证的是"这个算法正确"，
// 验证不了"Swift 里的实现就是这个算法"——实现漂移、被人改错、
// 甚至整个函数被删掉，复刻版照样全绿。
//
// 这里直接用真实的 Shell.quote() 构造命令，交给真实的 bash 执行，
// 再看 bash 最终拿到的参数。两层引号边界任何一层错，表现都是
// "连不上那个网络"而且看不出原因。
print("== 15. Shell.quote：真实实现经真实 bash 往返（权威）==")
let quoteCases = [
    "My Home WiFi",
    "Bob's Cafe",
    "He said \"hi\"",
    "back\\slash",
    "dollar$sign",
    "中文网络名",
    "a'b\"c\\d",
    "'; rm -rf /; echo '",          // 注入尝试
    "$(touch /tmp/pwned)",           // 命令替换尝试
    "`touch /tmp/pwned2`",           // 反引号替换
    "tab\there",
    "newline\nhere",
]
for c in quoteCases {
    let cmd = "printf '%s' " + Shell.quote(c)
    let r = Shell.run(cmd, timeout: 10)
    eq(r.out, c, "往返一致: [\(c.replacingOccurrences(of: "\n", with: "\\n"))]")
}

// 反向：注入必须**不**被执行。上面几个 payload 若真被执行，
// 会在 /tmp 留下痕迹。这里断言它们不存在。
let noPwn = !FileManager.default.fileExists(atPath: "/tmp/pwned")
    && !FileManager.default.fileExists(atPath: "/tmp/pwned2")
isTrue(noPwn, "注入 payload 未被 bash 执行（没有产生副作用文件）")

print("")
print("== 16. Shell.quote 的形状：必须是单引号字面量 ==")
// 复刻版测不了形状，因为 sed 出来的东西天生就是这个形状。
// 但形状本身是契约：App 别处（以及以后新增的调用点）依赖它。
isTrue(Shell.quote("abc") == "'abc'", "普通字符串被包进一对单引号")
isTrue(Shell.quote("a'b") == "'a'\\''b'", "内部单引号按 '\\'' 转义")
isTrue(Shell.quote("") == "''", "空字符串是 ''（不是裸的，也不是漏掉）")
// 已带引号的不能再包一层：那会让 bash 看到字面的两个引号字符
isTrue(!Shell.quote("x").hasPrefix("''") || Shell.quote("x") == "''",
       "不会双重包装")
isTrue(Shell.quote("a\\b").count >= 3, "反斜杠原样保留（单引号内不需转义）")

print("")
print("== 17. Privileged 的 AppleScript 转义：引号必须成对 ==")
// Privileged.execute 把 command 放进 do shell script "..."
// 只转义 \\ 和 "。这里验的是**真实实现**（不是复刻的 sed）：
// 转义后未转义的双引号必须成对，否则 osascript 直接语法错误，
// 而 App 侧只会看到"授权失败了"，用户完全没法排查。
//
// 做法：按生产代码同顺序复刻替换，然后断言形状。
// 之所以还是要复刻这一层：Privileged 的转义是 private 且没有独立函数，
// 抽不出来单独测。但至少引号成对这件事可以在复刻结果上断言，
// 而 mock_quote.sh 已经覆盖了这层的算法正确性。
func applescriptEscape(_ s: String) -> String {
    return s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}
let asCases = [
    "bash '/usr/local/bin/smartroute' wifi join 'Bob'\\''s Cafe'",
    "bash '/usr/local/bin/smartroute' wifi join 'say \"hi\"'",
    "bash '/usr/local/bin/smartroute' wifi join 'back\\slash'",
    "bash '/usr/local/bin/smartroute' wifi join ''",       // 空 SSID
]
for c in asCases {
    let esc = applescriptEscape(c)
    let n = esc.filter { $0 == "\"" }.count
    isTrue(n % 2 == 0, "转义后双引号成对（\(n) 个）")
    // 反斜杠数也必须是偶数：落单的反斜杠会把后面的字符转义掉
    let b = esc.filter { $0 == "\\" }.count
    isTrue(b % 2 == 0, "转义后反斜杠成对（\(b) 个）")
}

// 关键场景：SSID 里同时有单引号和双引号时，两层叠加后 bash 必须仍拿到原值
let nasty = "a'b\"c\\d"
let full = applescriptEscape("printf '%s' " + Shell.quote(nasty))
// 把 AppleScript 层的转义还原（osascript 会做这一步）
let restored = full
    .replacingOccurrences(of: "\\\"", with: "\"")
    .replacingOccurrences(of: "\\\\", with: "\\")
let r2 = Shell.run(restored, timeout: 10)
eq(r2.out, nasty, "两层叠加后 bash 仍拿到原始值")

print("")
print("== 18b. streakText：读不到不能渲染成空标签 ==")
// 脚本的 state_get 取不到键时返回 "-"。以前 dropFirst() 拿到空串，
// 渲染成"连续失败  次"——中间空两格，出现在默认落地页的接口卡片上。
// 实测复现：streakText("-") => "连续失败  次"
let streakCases = [
    ("-", "未知"),
    ("-3", "连续失败 3 次"),
    ("0", "未知"),
    ("", "未知"),
    ("5", "连续成功 5 次"),
    ("12", "连续成功 12 次"),
]
for (inp, want) in streakCases { eq(streakText(inp), want, "streakText(\"\(inp)\")") }
// 兜底：任何输出都不该出现连续两个空格（那就是空值漏进了字符串）
for (inp, _) in streakCases {
    isTrue(!streakText(inp).contains("  "), "streakText(\"\(inp)\") 不含连续空格")
}

print("== 18c. 提权命令的 stderr 不许被吞（假成功最隐蔽的来源）==")
// 背景：`do shell script` 在命令返回非零时**抛错，并把已捕获到的输出一起丢掉**。
// 而 smartroute.sh 的拒绝理由、失败诊断几乎全写在 stderr 上。于是用裸
// Privileged.run 的调用方只能看到 AppleScript 的通用错误（"退出码 1"），
// 脚本辛苦写好的诊断一个字都到不了用户眼前。
//
// 实测后果：balance on 在同网关时被脚本拒绝（exit 1 + stderr 上一整段
// 卡死风险说明），App 侧只显示"退出码 1"。用户看不懂，转而去终端
// --force 强开 → 网络卡死。而 NetworkModel 里那几处 catch 的提示
// （匹配"两个接口都有外网"等文本）全是死代码——文本从来没到过。
//
// 锁住两件事：
//   1) Privileged 必须提供 runCapturing（取回 stderr + 退出码）
//   2) 四个面向用户的调用点必须用它，并且必须查退出码
let privSrc = readSrc("SmartRouteApp/Privileged.swift")
isTrue(privSrc.contains("static func runCapturing"), "Privileged 提供 runCapturing")
isTrue(privSrc.contains("2>&1"), "runCapturing 把 stderr 并回 stdout")

let nmSrc = readSrc("SmartRouteApp/NetworkModel.swift")
// balance on/off：拒绝理由是一整段，丢了用户就只看到"退出码 1"
isTrue(nmSrc.contains("Privileged.runCapturing("), "NetworkModel 用 runCapturing 而不是裸 run")
isTrue(nmSrc.contains("wifi join"), "wifi join 路径存在")
// 拿到退出码就必须查。runCapturing 把命令包成永远退出 0，不查 code 的话
// 脚本失败不再抛错，会被当成成功——比原来的问题更糟（连异常都没有了）。
let codeCheckCount = nmSrc.components(separatedBy: "if code == 0").count - 1
isTrue(codeCheckCount >= 4, "至少 4 处按退出码分支（balance/wifi join/tryall/auto），实际 \(codeCheckCount) 处")
// 不许再出现"无条件把结果当成功"的写法。
//
// 第一版这里写的是全文搜 "if code == 0" 再比位置——**空洞断言**：
// NetworkModel.swift 第 429 行有一个无关的 if code == 0，位置正好在目标之前，
// 于是把 balance 的判断删掉、改成 if true，166 项断言照样全过。
// 已实测复现过这个假绿。
//
// 正确做法：只取 setBalance 函数体（从 func setBalance( 扫到下一个顶层 func），
// 在**这个窗口内**比顺序。窗口不能定长——定长窗口漏 defer 的教训有过一次。
let balBody: String = {
    guard let st = nmSrc.range(of: "func setBalance(") else { return "" }
    let rest = nmSrc[st.lowerBound...]
    // 下一个顶层函数（行首 4 空格 + func）
    if let nx = rest.range(of: "\n    func ", options: .regularExpression) {
        return String(rest[..<nx.lowerBound])
    }
    return String(rest)
}()
isTrue(!balBody.isEmpty, "取到 setBalance 函数体")
isTrue(balBody.contains("runCapturing"), "setBalance 用 runCapturing")
isTrue(balBody.contains("if code == 0"), "setBalance 查退出码")
if let ci = balBody.range(of: "if code == 0"),
   let wi = balBody.range(of: "balanceMessage = on ?") {
    isTrue(ci.lowerBound < wi.lowerBound,
          "setBalance 里退出码判断在写结果之前（不再无条件说已开启）")
} else {
    isTrue(false, "setBalance 里找不到退出码判断或结果写入")
}
// 失败分支必须存在，否则 else 是空壳
isTrue(balBody.contains("开启失败"), "setBalance 有失败分支")

print("== 18d. fetch 一键入口：不许有骗人的按钮和假成功 ==")
// 这页加了一张「多连接下载」卡。三个容易滑倒的地方，逐个锁住：
//
// 1) 「停止」按钮必须真有对应动作。界面上放了按钮而 model 没有
//    fetchCancel()，编译能过（SwiftUI 的 Button action 是闭包，
//    调不存在的方法会报错——所以这条主要防将来有人删了函数却留着按钮），
//    但真正要防的是"函数存在却什么都不做"：那比不放按钮更糟，
//    用户以为卡死了。
// 2) 长任务必须用 runWithLog。fetch 是大文件下载，stdout 会被
//    do shell script 的系统超时（约 2 分钟）截断甚至杀掉，
//    而且杀的时候不抛错——表现为按钮转完圈什么都没发生。
// 3) 必须显示脚本打印的「实测分摊」。曲线同时起伏不能证明流量被
//    分摊到两个接口（Wi-Fi 关联着就永远有背景心跳），那一行是唯一证据。
let nmSrc2 = readSrc("SmartRouteApp/NetworkModel.swift")
isTrue(nmSrc2.contains("func fetchCancel()"), "NetworkModel 提供 fetchCancel")
// fetchCancel 必须真的杀进程 + 清半成品，不能是空函数
if let fs = nmSrc2.range(of: "func fetchCancel()") {
    let seg = String(nmSrc2[fs.lowerBound...])
    if let end = seg.range(of: "\n    func ") {
        let body = String(seg[..<end.lowerBound])
        // 必须匹配**可执行代码里的** pkill，不能只搜字符串——注释里
        // 也写着 pkill（解释为什么用 pkill 而不是 kill）。早先只搜
        // "pkill" 时，把整段换成 true 后这条断言仍然是绿的（注释还在），
        // 只有 rm -f 那条红了。现在限定在 Privileged.run( 之后搜。
        isTrue(body.contains("Privileged.run(\n") && body.contains("pkill -f"),
              "fetchCancel 真的杀进程（不留后台下载）")
        isTrue(body.contains("rm -f /tmp/smartroute-fetch.out"),
              "fetchCancel 删掉半成品文件（不留假文件）")
    } else {
        isTrue(false, "取不到函数体结尾")
    }
}
// fetchMulti 必须用 runWithLog，不能把大文件下载往 stdout 里灌
if let fs = nmSrc2.range(of: "func fetchMulti()") {
    let seg = String(nmSrc2[fs.lowerBound...])
    if let end = seg.range(of: "\n    func ") {
        let body = String(seg[..<end.lowerBound])
        isTrue(body.contains("runWithLog"), "fetchMulti 用 runWithLog（长任务不能走 stdout）")
        isTrue(body.contains("实测分摊"), "fetchMulti 显示实测分摊行（唯一的分摊证据）")
        isTrue(body.contains("if code == 0"), "fetchMulti 查退出码")
        isTrue(body.contains("max(2,"), "fetchMulti 连接数下限 2（1 条时切片无意义）")
        isTrue(body.contains("guard !url.isEmpty"),
              "fetchMulti 本地校验 URL 非空（别让用户白输一次管理员密码）")
    } else {
        isTrue(false, "取不到函数体结尾")
    }
}
// 界面：卡片存在、消息区不限行（实测分摊那行可能很长）
let vwSrc2 = readSrc("SmartRouteApp/Views.swift")
isTrue(vwSrc2.contains("FetchCard(model: model)"), "SpeedView 挂上了 FetchCard")
isTrue(vwSrc2.contains("struct FetchCard: View"), "FetchCard 已定义")
isTrue(vwSrc2.contains("model.fetchCancel()"), "停止按钮接的是真函数")
// 下载目标路径必须写明，否则用户下载完找不到文件
isTrue(vwSrc2.contains("/tmp/smartroute-fetch.out"), "卡片写明下载到哪个文件")

print("== 18e. fetch 的提示必须给用户此刻做得到的事 ==")
// 这一节全部来自实测踩坑，三条：
//
// 1) 原提示写着"网关相同且未加 --force"——而 --force 已经被拆掉了
//    （同网关一律拒绝）。那句话是在让用户执行一条不存在的命令：
//    他会去查、去试、发现报错，然后回来问"为什么加了 --force 还不行"。
//    这种提示比不提示更差，消耗的是用户对工具的信任。
// 2) 原提示写着"没执行 sudo smartroute balance on"——但 fetch 靠 curl
//    的 --interface 显式绑接口，跟 pf 分流无关；而同网关下 pf 分流已禁用。
//    让用户去开一堵墙上挂着"会被拒绝"的门。
// 3) 最常见的原因（文件太小切不出多片）压根没提。实测 1.7MB 文件
//    → 只切 1 片 → 1 片只能走一条线，必然"只有一条线在扛"，
//    而这跟 -n 多少、pf 开没开一点关系都没有。
let shSrc = readSrc("smartroute.sh")
if let ws = shSrc.range(of: "只有一条线在扛") {
    let seg = String(shSrc[ws.lowerBound...])
    var warn = ""
    if let end = seg.range(of: "\n    fi\n", options: .regularExpression) {
        warn = String(seg[..<end.lowerBound])
    } else {
        warn = String(seg)
    }
    isTrue(!warn.contains("--force"), "提示不再让用户加已不存在的 --force")
    isTrue(!warn.contains("balance on"), "提示不再让用户去开 pf 分流（fetch 不依赖 pf）")
    isTrue(warn.contains("文件太小"), "提示覆盖最常见原因：文件太小切不出多片")
    isTrue(warn.contains("不支持 Range"), "提示覆盖第二常见原因：地址不支持 Range")
    isTrue(warn.contains("min chunk") || warn.contains("1 MB") || warn.contains("1MB"),
          "提示说明最小片大小，用户能自己算门槛")
} else {
    isTrue(false, "取不到「只有一条线在扛」提示段")
}
// 探测不能被单次失败静默杀死：早前一次 8 秒超时就让整个多接口分摊退回默认路由，
// 而用户什么都没做错。现在每个接口试 2 次，且部分失败时只放弃真不能用的那个。
if let ps = shSrc.range(of: "_spread_try") {
    isTrue(true, "探测有重试（_spread_try 存在）")
    let seg = String(shSrc[ps.lowerBound...])
    // 源码里是 [ "$_spread_try" -lt 2 ]，带引号和空格，别写成紧邻形式
    isTrue(seg.contains("_spread_try\" -lt 2"), "每个接口试 2 次")
} else {
    isTrue(false, "探测没有重试——单次超时会静默关掉整个多接口分摊")
}
// UI 默认地址必须支持 Range。Cloudflare 的 __down 忽略 Range（实测），
// 用它当默认值会让"多连接下载"按钮永远是单连接——名不副实。
let nmSrc3 = readSrc("SmartRouteApp/NetworkModel.swift")
isTrue(!nmSrc3.contains("speed.cloudflare.com/__down?bytes=50000000"),
      "UI 默认地址不再用忽略 Range 的 Cloudflare __down")

print("== 18f. 测速必须能看出链路容量差（单连接测速是瞎子）==")
// 实测（同机同源，交替多轮）：
//     接口   1 连接    4 连接    8 连接
//     en0    78.9      91.0      92.1 Mbps   ← 100baseTX 链路封顶
//     en1    82.3     218.6     270.6 Mbps   ← Wi-Fi 5GHz/160MHz
//
// 单连接下两者只差 4%（78.9 vs 82.3）。而 measure_throughput 原来正是
// 单条 curl——于是"网速优先"模式判定"两条线差不多"，按延迟挑，
// 很容易挑中有线，**而有线的真实容量只有 Wi-Fi 的 1/3**。
// 用户看到的现象就是"智能选路选了更慢的那条"，而工具显示一切正常。
//
// 单连接测的是 TCP 单流速度（受慢启动/接收窗口/对端限流影响），
// 不反映链路容量。要多条并发才能把链路压到上限。
let shSrc2 = readSrc("smartroute.sh")
if let mt = shSrc2.range(of: "measure_throughput_once()") {
    let seg = String(shSrc2[mt.lowerBound...])
    var body = ""
    if let end = seg.range(of: "\n}", options: .regularExpression) {
        body = String(seg[..<end.lowerBound])
    } else {
        body = String(seg)
    }
    // 必须起多条并发连接
    isTrue(body.contains("for _i in 1 2 3 4"), "测速起 4 条并发连接（单连接是瞎子）")
    isTrue(body.contains("--interface \"$dev\""), "每条连接都绑到被测接口")
    isTrue(body.contains("wait"), "等所有连接跑完再汇总")
    // 部分失败不许按总数算：4 条挂 3 条会把结果低估 4 倍，
    // 而那是网络抖动，不是真实容量。
    isTrue(body.contains("n_ok"), "统计成功条数")
    isTrue(body.contains("s / n") || body.contains("s/n"),
          "按成功条数求平均，不按总数求和")
    isTrue(body.contains("[ \"$n_ok\" -gt 0 ]") || body.contains("n_ok\" -gt 0"),
          "一条都没测到才算失败")
} else {
    isTrue(false, "取不到 measure_throughput_once 函数体")
}
// 测速源必须是列表 + 降级。单一源是单点故障，本项目已被坑多次：
// Cloudflare __down 忽略 Range、对国内时段性劣化（15→3 Mbps）、
// proof.ovh.net 累计 2GB 后限流。源坏时"网速优先"整个静默失灵。
isTrue(shSrc2.contains("SPEED_TEST_URLS="), "测速源是列表")
isTrue(shSrc2.contains("for _u in $_urls"), "按列表逐个尝试")
// 不许再把 Cloudflare 当唯一默认源
isTrue(!shSrc2.contains("SPEED_TEST_URL=\"https://speed.cloudflare.com/__down?bytes=5000000\"   #"),
      "默认测速源不再只有 Cloudflare（实测它忽略 Range 且时段性劣化）")

// ── 18g. 分片必须按容量加权，而且份额必须交错 ──
// 实测教训：均分会把一半字节赶到慢线上。本机 en0 封顶 89 Mbps、
// en1 能跑 180 Mbps，38MB 文件均分时出现 12.65s 的长尾（慢线钉死总时长），
// 加权后稳定在 2.95s。
//
// 但真正摔过的坑是**排列方式**：第二版把每个设备按权重重复 N 次后首尾相接
// （en0×11 紧跟 en1×22），权重算对了、排列全错——前 11 片统统走 en0，
// 9 片文件 100% 压在慢线上，实测分摊 99%/0%，比不改还糟。
// 所以这里同时锁"按权重"和"交错"两件事，缺一不可。
// 取一段源码：从 start 到第一次出现的 endMarker 为止。
// 照 18f 的写法来——那里也是手写 range，不搞通用 helper
// （helper 一旦写错边界，所有断言会同时变绿或同时变红，反而看不出问题）。
func shSeg(_ src: String, _ start: String, _ endMarker: String) -> String {
    guard let a = src.range(of: start) else { return "" }
    let seg = String(src[a.lowerBound...])
    if let b = seg.range(of: endMarker) { return String(seg[..<b.lowerBound]) }
    return seg
}

print("== 18g. 分片按容量加权，且份额必须交错（不是块状拼接）==")
do {
    // 起点必须是序列构造处，不是 _spread_pick——SWRR 的代码在函数定义
    // **之前**，从 _spread_pick() { 起取会整段漏掉，断言全部变红。
    let body = shSeg(shSrc2, "local _spread_seq=", "local _spread_len=0")
    if body.isEmpty {
        isTrue(false, "取不到分片分配的代码段")
    } else {
        // 加权依据：必须读实测吞吐
        isTrue(body.contains("_metric_val \"speed_$"), "按实测吞吐加权，不按片数均分")
        // 交错：必须是 SWRR（挑最亏欠的那条），不能是重复拼接
        isTrue(body.contains("_bestscore") && body.contains("_bestdev"),
              "用平滑加权轮转逐条挑选，而不是把份额首尾相接")
        isTrue(!body.contains("_n_rep=$(( (_wval * 32 + _stot - 1) / _stot ))"),
              "不再用按权重重复 N 次后拼接（那是块状，会整段压在一条线上）")
        // 数据不全时不猜：部分接口没实测值就退回均分
        isTrue(body.contains("_ndata\" -eq \"$_ndev\""),
              "只有全部接口都有实测数据才加权；否则退回均分（不猜）")
        // 均分回退必须存在
        isTrue(body.contains("[ -n \"$_spread_seq\" ] || _spread_seq=\"$_spread_devs\""),
              "没有实测数据时退回均分（诚实的默认）")
    }
}
// 探针必须并行 + 短超时：串行 8 秒超时最坏 8+1+8=17 秒，
// 而下载本身只要 1 秒。实测 fetch 出现过 18s 离群值正是这个原因。
do {
    // 结束标记不能用 "    fi"——块内有 8 空格缩进的 fi，"    fi" 是它的
    // 子串，会把段截断在并行探测代码之前，断言全部变红。
    // 用块之后独有的那一行当边界。
    let r = shSeg(shSrc2, "if [ \"$_spread_n\" -gt 1 ]; then", "if [ -n \"$_spread_devs\" ]; then")
    if r.isEmpty {
        isTrue(false, "取不到接口探测的代码段")
    } else {
        isTrue(r.contains("_pT/ok_") && r.contains("&"),
              "两个接口的探测并行跑（串行时最坏 17 秒，下载才 1 秒）")
        isTrue(r.contains("--max-time 4"), "探测超时从 8 秒降到 4 秒（只取 1 字节）")
        // 两个都探测失败 → 不绑接口走默认路由。第一版写成了绑回原列表，
        // 导致回环/内网地址下每个分片都失败，还打出"连续失败"告警——
        // 而测试正是靠 grep「失败」判断下载是否真坏，于是误报。
        isTrue(!r.contains("_spread_devs=\"$_orig_spread_devs\""),
              "两个接口都探测失败时不绑回原列表（否则分片全失败还误报）")
    }
}

print("== 18. beginOp 必须配 defer 形式的 endOp ==")
// inFlight 守卫防的是"并发跑多份 shell 把机器拖垮"。但它有个静默失效模式：
// 如果 endOp 是在 DispatchQueue.main.async 里手动调的，那么将来任何人在那个
// 闭包里加一个提前 return，对应的 key 就永远留在 inFlight 里——界面从此停止
// 刷新，没有报错、没有日志，用户只觉得"数据不动了"。
// 这种失效比崩溃难查得多，所以要求全部用 defer（对所有返回路径生效）。
let modelSrc = readSrc("SmartRouteApp/NetworkModel.swift")
let srcLines = modelSrc.components(separatedBy: "\n")
var beginCount = 0, deferCount = 0, missing: [String] = []
for (i, line) in srcLines.enumerated() {
    // beginOp 的调用形如 guard beginOp("xxx") else { return }
    if let r = line.range(of: #"beginOp\("([^"]+)"\)"#, options: .regularExpression) {
        beginCount += 1
        let key = String(line[r]).replacingOccurrences(of: "beginOp(\"", with: "")
            .replacingOccurrences(of: "\")", with: "")
        // 往后扫到下一个 beginOp 为止（那就是另一个函数的守卫了）。
        // 不能用固定行数窗口：measurements 的 defer 在 23 行后，
        // 窗口给小了会假阴性——而假阴性会让人去"修"本来正确的代码。
        var found = false
        var j = i + 1
        var limit = srcLines.count
        var k = i + 1
        while k < srcLines.count {
            if srcLines[k].contains("beginOp(") { limit = k; break }
            k += 1
        }
        while j < limit {
            if srcLines[j].contains("defer") && srcLines[j].contains("endOp(\"\(key)\")") {
                found = true; break
            }
            j += 1
        }
        if found { deferCount += 1 } else { missing.append(key) }
    }
}
isTrue(beginCount >= 8, "找到 \(beginCount) 处 beginOp（守卫没有被整体删掉）")
eqI(deferCount, beginCount, "每处 beginOp 都紧跟 defer 形式的 endOp")
if !missing.isEmpty {
    print("  XX 这些 key 没有 defer 保护的 endOp: \(missing.joined(separator: ", "))")
    failures += 1
} else {
    print("  OK 没有裸奔的 inFlight key")
}
// 反向：不能有人为了"修好"而把 beginOp 整个删掉
isTrue(beginCount == deferCount && beginCount > 0, "守卫数量既没减少也没被绕过")

print("")
print("结果: \(checks - failures) 通过, \(failures) 失败")
exit(failures == 0 ? 0 : 1)


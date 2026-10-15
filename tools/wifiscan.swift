// wifiscan.swift —— 免权限判断"哪些已保存网络在附近 + 信号多强"
//
// 为什么需要它：
//   macOS 上通用 Wi-Fi 扫描（scanForNetworks(withSSID: nil)）拿不到 SSID
//   （要「定位服务」权限），按指定 SSID 扫描（withSSID: Data）却不需要权限。
//   我们只关心"已保存的网络在不在范围"，正好可以用后者。
//
//   有了它就能：把候选网络按信号排序、跳过多年来不在范围的网络、
//   在界面上把够不着的网络置灰——都不需要打断当前连接，
//   也不需要向用户要定位权限。
//
// 用法：wifiscan SSID1 SSID2 ...
// 输出（TSV，每行一个）：SSID \t rssi \t channel \t fresh
//   rssi    最强 BSSID 的信号；不在范围输出 -
//   channel 最强 BSSID 的信道；不在范围输出 -
//   fresh   1=这次真的发了探测；0=系统直接返回了缓存
//
// 【关键陷阱】fresh=0 且 rssi=- 时不能信。
//   系统对扫描请求有冷却：刚扫过 A，紧接着问 B，可能直接用上次的缓存回答，
//   而那份缓存里只有 A 的结果——于是 B 被误判成"不在范围"。
//   实测：先扫 CZ-305(1.27s)，紧接着问 CZ-BH-407 只用 0.01s 且报空，
//   但单独扫 CZ-BH-407 明明能拿到 -60。所以"找不到"必须配 fresh=1 才算数。
//   （反过来，rssi 有值时永远可信，不管 fresh。）
//
// 编译：swiftc -O wifiscan.swift -o wifiscan
import CoreWLAN
import Foundation

guard let iface = CWWiFiClient.shared().interface() else {
    FileHandle.standardError.write("no Wi-Fi interface\n".data(using: .utf8)!)
    exit(1)
}

// 每个 SSID 的结果：rssi（- 表示没找到）、信道、这次是否真发了探测
struct Hit { let name: String; let rssi: Int; let ch: Int; let fresh: Bool }

var anyFresh = false

// --quick：只扫一轮，不重试。给"自动切换"这类不能等的场合用。
// 默认（交互式）：对"没找到且没真扫"的再问几轮，每轮间隔约 5 秒——
// 实测系统约每 5 秒才肯真扫一次，等 1~3 秒都不够。
var quick = false
let argv = CommandLine.arguments
if argv.contains("--quick") { quick = true }
let names = argv.dropFirst().filter { $0 != "--quick" && !$0.isEmpty }

func scanOne(_ name: String) -> Hit {
    let t0 = Date()
    let data = name.data(using: .utf8) ?? Data()
    let nets = (try? iface.scanForNetworks(withSSID: data)) ?? []
    let elapsed = Date().timeIntervalSince(t0)
    let fresh = elapsed > 0.3
    if fresh { anyFresh = true }
    // 一个 SSID 可能有多个 BSSID（双频/三频/Mesh），取信号最强的
    if let b = nets.max(by: { $0.rssiValue < $1.rssiValue }) {
        return Hit(name: name, rssi: b.rssiValue, ch: b.wlanChannel?.channelNumber ?? -1, fresh: fresh)
    }
    return Hit(name: name, rssi: -999, ch: -1, fresh: fresh)
}

let RETRY_GAP = 5.0
let MAX_PASS = 3
var pending = Array(names)
var results: [String: Hit] = [:]

for pass in 1...MAX_PASS {
    var retry: [String] = []
    for name in pending {
        let h = scanOne(name)
        results[name] = h
        // 找到了永远可信；没找到但没真扫的，下一轮再问
        if h.rssi == -999 && !h.fresh && !quick && pass < MAX_PASS { retry.append(name) }
    }
    if retry.isEmpty { break }
    pending = retry
    Thread.sleep(forTimeInterval: RETRY_GAP)
}

for name in names {
    guard let h = results[name] else { continue }
    if h.rssi == -999 {
        print("\(name)\t-\t-\t\(h.fresh ? 1 : 0)")
    } else {
        print("\(name)\t\(h.rssi)\t\(h.ch)\t\(h.fresh ? 1 : 0)")
    }
    fflush(stdout)
}
// 一个都没真扫过（全命中缓存）时返回 2，让调用方知道这次结果可能不全
exit(anyFresh ? 0 : 2)

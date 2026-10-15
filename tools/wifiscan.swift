// wifiscan.swift —— 免权限读 Wi-Fi：附近网络扫描 + 当前连接状态
//
// 为什么需要它：
//   1) 附近网络：macOS 的通用 Wi-Fi 扫描（scanForNetworks(withSSID: nil)）
//      拿不到 SSID（要「定位服务」权限），但**按指定 SSID 扫描**
//      （withSSID: Data）不需要权限。我们只关心"已保存的网络在不在范围"，
//      正好用后者。附带好处：不打断当前连接。
//   2) 当前状态：system_profiler SPAirPortDataType 一次要约 1.6 秒，
//      而 App 每 5 秒轮询一次、status 也要用。CoreWLAN 同样这几个量
//      （信号/信道/速率/噪声）只要几十毫秒。
//
// 用法：
//   wifiscan SSID1 SSID2 ...    扫描指定 SSID
//   wifiscan --quick SSID...    只扫一轮，不重试（给不能等的场合）
//   wifiscan --current          读当前连接的网络
//
// 输出（都是 TSV）：
//   扫描：  SSID \t rssi \t channel \t fresh
//            rssi=- 表示没找到；fresh=1 表示这次真发了探测
//   当前：  rssi \t channel \t rate \t noise
//
// 【关键陷阱】fresh=0 且 rssi=- 时不能信。
//   系统对扫描请求有冷却：刚真扫过一个 SSID，紧接着问下一个，
//   可能直接用上次的缓存回答，而缓存里只有上一个的结果——于是这个被
//   误判成"不在范围"。实测：先问 A（真扫 1.3s），紧接着问 B 只用 0.02s
//   且报空，但单独问 B 能拿到 -60。系统约每 5 秒才肯真扫一次。
//   所以"没找到"必须配 fresh=1 才算数；而"找到了"（rssi 有值）永远可信。
//
// 编译：swiftc -O wifiscan.swift -o wifiscan
import CoreWLAN
import Foundation

// 一次扫描的结果：rssi（-999 表示没找到）、信道、这次是否真发了探测
struct Hit { let name: String; let rssi: Int; let ch: Int; let fresh: Bool }

guard let iface = CWWiFiClient.shared().interface() else {
    FileHandle.standardError.write("no Wi-Fi interface\n".data(using: .utf8)!)
    exit(1)
}

// ---------- 当前连接 ----------

/// 读当前连接的网络：rssi / 信道 / 协商速率 / 噪声底。
/// 拿不到就退出码 1，由调用方回退到 system_profiler。
func currentInfo() {
    // 注意：CWInterface.wlanChannel 是**方法**（要加括号），
    // 而 CWNetwork.wlanChannel 是属性。两者不一致，踩过一次。
    let ch = iface.wlanChannel()?.channelNumber ?? -1
    let noise = iface.noiseMeasurement()
    let rate = Int(iface.transmitRate())
    // 没连上时 rssi 会是 0 之类，交给调用方判断
    print("\(iface.rssiValue())\t\(ch)\t\(rate)\t\(noise)")
    fflush(stdout)
    exit(0)
}

// ---------- 附近网络扫描 ----------

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

var anyFresh = false

// --quick：只扫一轮，不重试。给"自动切换"这类不能等的场合用。
// 默认（交互式）：对"没找到且没真扫"的再问几轮，每轮间隔约 5 秒——
// 实测系统约每 5 秒才肯真扫一次，等 1~3 秒都不够。
var quick = false
let argv = CommandLine.arguments
if argv.contains("--quick") { quick = true }

if argv.contains("--current") { currentInfo() }

let names = argv.dropFirst().filter { $0 != "--quick" && $0 != "--current" && !$0.isEmpty }

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

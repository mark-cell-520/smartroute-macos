import SwiftUI

// MARK: - 侧边栏顶部状态头

/// 侧边栏顶部的一小块实时状态：当前走哪条线、通不通。
///
/// 为什么加它：这个 App 的核心问题只有一句"我现在走哪条线"，而答案在
/// 「状态」页的第二屏。用户从菜单栏点"打开面板"时想看的正是这个，
/// 却要先在侧边栏找到「状态」、再往下滚过同网关横幅和链路速率卡才看到。
/// 侧边栏是唯一始终可见的区域，把答案放这儿，一眼就看到，不用切页。
///
/// 视觉上也是侧边栏唯一非列表的元素，给原本一片灰的列表一个锚点。
struct SidebarStatusHeader: View {
    @ObservedObject var model: NetworkModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapXS) {
            HStack(spacing: Theme.gapXS) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text("当前线路").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // 守护进程没装时不说"未知"——那时候根本没有自动选路在跑，
                // 默认路由就是系统自己选的，显示出来仍然是真的。
                Text(model.snapshot.defaultDevice.isEmpty ? "读取中" : model.snapshot.defaultDevice)
                    .font(.caption.monospaced().weight(.medium))
            }
            HStack(spacing: Theme.gapXS) {
                Image(systemName: activeIcon)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                    .frame(width: 12)
                Text(activeName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text(probeText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.horizontal, Theme.gapS)
        .padding(.vertical, Theme.gapS)
        // 用和卡片同一套底色/描边，让侧边栏顶部和右侧内容看起来是一套东西，
        // 而不是飘在列表上方的一块异类。
        .background(
            RoundedRectangle(cornerRadius: Theme.gapS, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.gapS, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: Theme.hairline)
        )
        .padding(.horizontal, Theme.gapS)
        .padding(.top, Theme.gapS)
        .help("默认路由现在走哪个接口、那个接口通不通外网")
    }

    /// 当前默认路由对应的接口角色名（"以太网" / "Wi-Fi"）
    ///
    /// 不调用 Views.swift 的 deviceDisplayName：那个函数在 Views.swift 里，
    /// 而 tests/mock_swift_parse.sh 的构建 glob 排除了 Views.swift
    /// （它只含 View，会拖进一堆 UI 依赖）。在这里调它，测试构建直接编不过。
    /// 角色名脚本已经判好并存进 InterfaceInfo.role，直接取就行。
    private var activeName: String {
        let dev = model.snapshot.defaultDevice
        if dev.isEmpty { return "—" }
        let role = model.snapshot.interfaces.first { $0.device == dev }?.role ?? ""
        return role.isEmpty ? dev : role
    }

    private var activeIcon: String {
        let dev = model.snapshot.defaultDevice
        if dev.isEmpty { return "questionmark.circle" }
        // InterfaceInfo 没有 icon 字段，按 role 映射（AppPage 那套语义色/图标
        // 也是这么做的）。role 由脚本判定，比自己猜 en0/en1 可靠。
        let role = model.snapshot.interfaces.first { $0.device == dev }?.role ?? ""
        switch role {
        case "以太网": return "cable.connector"
        case "Wi-Fi":  return "wifi"
        default:       return "cable.connector"
        }
    }

    /// 当前接口的探测结果（ethOK / wifiOK 由接口角色决定）
    private var probe: String {
        let dev = model.snapshot.defaultDevice
        guard !dev.isEmpty else { return "-" }
        // 用角色判断而不是设备名硬编码：InterfaceInfo.role 已经由脚本判好
        // （"以太网"/"Wi-Fi"），比自己猜 en0/en1 可靠。
        let role = model.snapshot.interfaces.first { $0.device == dev }?.role ?? ""
        switch role {
        case "以太网": return model.snapshot.ethOK
        case "Wi-Fi":  return model.snapshot.wifiOK
        default:       return "-"
        }
    }

    private var probeText: String { Theme.text(forProbe: probe) }

    private var statusColor: Color {
        Theme.color(forProbe: probe)
    }
}

import SwiftUI

// MARK: - 设计系统
//
// 目标：把散落在各页面里的"随手写的字体/颜色/间距"收敛成一套统一的视觉语言。
// 规则：
//   · 颜色只用语义色（ok/warn/bad/info），不直接写 Color.orange 这类原始色
//   · 卡片一律用 Card 组件，圆角/内边距/描边全站一致
//   · 状态徽标一律用 Pill，不再到处 .padding(.horizontal, 6).clipShape(Capsule())
//   · 空状态用 EmptyState，不再让页面白茫茫一片
enum Theme {

    // MARK: 品牌色（与 App 图标同一套渐变）
    static let brand     = Color(red: 0.20, green: 0.58, blue: 1.00)
    static let brandDeep = Color(red: 0.42, green: 0.28, blue: 0.98)

    // MARK: 语义色
    static let ok   = Color.green
    static let warn = Color.orange
    static let bad  = Color.red
    static let info = Color.blue
    static let idle = Color.secondary

    // MARK: 间距（4 的倍数）
    static let gapXS: CGFloat = 4
    static let gapS:  CGFloat = 8
    static let gapM:  CGFloat = 12
    static let gapL:  CGFloat = 18
    static let gapXL: CGFloat = 24

    // MARK: 圆角与描边
    static let radius: CGFloat = 12
    static let hairline: CGFloat = 1

    /// 探测结果 -> 语义色
    static func color(forProbe probe: String) -> Color {
        switch probe {
        case "ok":   return ok
        case "fail": return bad
        case "na":   return idle
        default:     return warn      // "-" 或未知：还没采到
        }
    }

    /// 探测结果 -> 中文
    static func text(forProbe probe: String) -> String {
        switch probe {
        case "ok":   return "有外网"
        case "fail": return "无外网"
        case "na":   return "未激活"
        default:     return "检测中"
        }
    }

    /// 探测结果 -> SF Symbol
    static func icon(forProbe probe: String) -> String {
        switch probe {
        case "ok":   return "checkmark.circle.fill"
        case "fail": return "xmark.circle.fill"
        case "na":   return "minus.circle.fill"
        default:     return "questionmark.circle.fill"
        }
    }
}

// MARK: - 卡片（替代裸 GroupBox）

/// 全站统一的卡片容器：圆角 + 细描边 + 极淡阴影，暗色模式下自动变深
struct Card<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Spacer()
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.gapL)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Color(nsColor: scheme == .dark ? .controlBackgroundColor : .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.10 : 0.07), lineWidth: Theme.hairline)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.05), radius: scheme == .dark ? 6 : 3, x: 0, y: 1)
    }
}

// MARK: - 状态徽标（替代到处手写的 Capsule）

struct Pill: View {
    let text: String
    var color: Color = Theme.info
    var icon: String? = nil
    var filled = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.caption2) }
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, Theme.gapS)
        .padding(.vertical, 3)
        .foregroundStyle(filled ? Color.white : color)
        .background(filled ? color : color.opacity(0.14))
        .clipShape(Capsule())
    }
}

// MARK: - 横幅提示（守护进程未装/需更新等）

struct Banner: View {
    let icon: String
    let color: Color
    let title: String
    let message: String
    let buttonTitle: String?
    let action: (() -> Void)?

    init(icon: String, color: Color, title: String, message: String,
         buttonTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon; self.color = color
        self.title = title; self.message = message
        self.buttonTitle = buttonTitle; self.action = action
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.gapM) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.gapM)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(Theme.gapM)
        .background(color.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(color.opacity(0.28), lineWidth: Theme.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

// MARK: - 空状态

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String?

    var body: some View {
        VStack(spacing: Theme.gapS) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - 加载中的按钮

struct LoadingButton: View {
    let title: String
    let icon: String
    var loading = false
    var prominent = true
    let action: () -> Void

    var body: some View {
        // 三元表达式没法同时推两种 ButtonStyle，用 Group 分流
        Group {
            if prominent {
                Button(action: action) { label }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.bordered)
            }
        }
        .disabled(loading)
    }

    @ViewBuilder private var label: some View {
        HStack(spacing: Theme.gapXS) {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon)
            }
            Text(loading ? "处理中…" : title)
        }
    }
}

// MARK: - 键值行（设置页/关于页常用）

struct KeyValueRow: View {
    let key: String
    let value: String
    var valueColor: Color = .primary
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(valueColor)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

// MARK: - 首次启动引导

/// 第一次打开 App 时显示的欢迎页：说清楚这个 App 干什么、要不要装守护进程。
/// 用 UserDefaults 记住"已看过"，且守护进程已装时直接跳过，不打扰老用户。
struct WelcomeView: View {
    @ObservedObject var model: NetworkModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("didSeeWelcome") private var didSee = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部品牌区
            VStack(spacing: Theme.gapM) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("SmartRoute 智能选路")
                    .font(.largeTitle.weight(.semibold))
                Text("网线没外网时自动切 Wi-Fi；两边都能用时按实测吞吐挑更快的那条")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Theme.gapXL)
            .padding(.bottom, Theme.gapL)

            Divider()

            // 三步说明
            VStack(alignment: .leading, spacing: Theme.gapM) {
                welcomeStep(
                    icon: "1.circle.fill", color: Theme.brand,
                    title: "看一眼现在的状态",
                    detail: "「状态」页显示谁在上网、网关通不通。一般插上网线就装好了，不用改任何设置。"
                )
                welcomeStep(
                    icon: "2.circle.fill", color: Theme.brand,
                    title: "装守护进程（推荐）",
                    detail: "装了以后开机自启，每 20 秒自动检测：以太网断网自动切 Wi-Fi，恢复自动切回。只需要一次管理员密码。"
                )
                // 必须说清楚它改什么。用户在这里点下"安装"，批准的是一个 root 级
                // 守护进程：会调整系统网络服务顺序、增删默认路由、双网并发还要
                // 启用系统 pf 写锚点、必要时自动打开 Wi-Fi。这些不说，等于让用户
                // 在一无所知的情况下交出管理员权限——发现时信任已经没了。
                welcomeStep(
                    icon: "shield.lefthalf.filled", color: Theme.warn,
                    title: "它会修改你的系统网络设置",
                    detail: "具体是：网络服务顺序、默认路由、双网并发的 pf 防火墙规则，必要时自动打开 Wi-Fi。不动 DNS、VPN、代理和 hosts。随时可在「守护进程」页暂停，或一键彻底卸载（会还原服务顺序）。"
                )
                welcomeStep(
                    icon: "3.circle.fill", color: Theme.brand,
                    title: "需要时再开双网并发",
                    detail: "「双网并发」页可以把流量按连接分摊到两条线路。这是实验特性，两条线走同一个网关时没有带宽收益。"
                )
            }
            .padding(Theme.gapXL)

            Spacer()

            Divider()

            HStack(spacing: Theme.gapM) {
                Button("先看看，不装") {
                    didSee = true
                    dismiss()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    didSee = true
                    dismiss()
                    model.installDaemon()
                } label: {
                    Label("安装守护进程", systemImage: "checkmark.shield.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.daemonInstalling)
            }
            .padding(Theme.gapL)
        }
        .frame(width: 620, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func welcomeStep(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.gapM) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 数据新鲜度徽标

/// 显示"x 秒前更新"，让用户知道 App 是活的、数据不旧。
/// 超过 30 秒变橙色提醒（说明采集可能卡了）。
/// 无内部定时器：跟随父视图的 5 秒刷新一起更新（少一个定时器就少一分卡顿）
struct FreshnessBadge: View {
    let since: Date
    var now: Date = Date()

    var body: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(seconds > 30 ? Theme.warn : Color.secondary)
            .help("上次成功采集数据的时间")
    }

    private var seconds: Int {
        Int(now.timeIntervalSince(since))
    }

    private var label: String {
        guard since > Date.distantPast else { return "尚未采集" }
        let s = max(0, seconds)
        if s < 60 { return "\(s) 秒前更新" }
        return "\(s / 60) 分 \(s % 60) 秒前更新"
    }
}

// MARK: - 文件面板呈现

/// 统一的 NSSavePanel/NSOpenPanel 呈现方式。
/// 之前直接写 `NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()` 有个坑：
/// new 出来的 NSWindow 没被显示过，拿它当 sheet 宿主面板会**不出现**，
/// 用户点了按钮没反应。这里：有可见窗口就用 sheet，没有就退化成普通模态窗口。
func presentPanel(_ panel: NSSavePanel, _ completion: @escaping (NSApplication.ModalResponse) -> Void) {
    if let win = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
        panel.beginSheetModal(for: win, completionHandler: completion)
        return
    }
    // 没有可见窗口（例如只开了菜单栏图标、面板被关掉）：退化成模态
    DispatchQueue.main.async { completion(panel.runModal()) }
}

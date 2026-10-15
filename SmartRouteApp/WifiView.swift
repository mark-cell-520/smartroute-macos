import SwiftUI

/// Wi-Fi 页：选网络、看信号、上不了网时自动换一个
///
/// 设计取舍（重要）：
///   · macOS 不给人免权限看"附近有哪些 Wi-Fi"——CoreWLAN 扫描要位置权限，
///     而为一个网络工具去要定位权限，用户第一反应是"这 App 想干嘛"。
///   · 但"已保存的网络"是免权限的，密码也在系统钥匙串里。
///     所以这里做的是：列出已保存网络，点一下就能切；自动切换靠逐个试连已保存网络。
///   · 代价：没保存过的新网络没法在这里连。界面里明确告诉用户去哪连（系统菜单栏），
///     而不是给一个注定失败的输入框。
struct WifiView: View {
    @ObservedObject var model: NetworkModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapM) {
                currentCard
                savedCard
                autoCard
                explainCard
            }
            .padding()
        }
        .onAppear {
            model.loadWifi()
            model.loadWifiFailover()
        }
    }

    // MARK: 当前连接

    private var currentCard: some View {
        Card(title: "当前 Wi-Fi", subtitle: "信号与信道免权限可读") {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                if model.wifiBars > 0 {
                    HStack(spacing: Theme.gapS) {
                        signalBars
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(model.wifiSignal) dBm")
                                .font(.title3.weight(.semibold).monospacedDigit())
                            Text("信道 \(model.wifiChannel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        signalHint
                    }
                } else {
                    EmptyState(icon: "wifi.slash",
                               title: "读不到 Wi-Fi 信号",
                               message: "Wi-Fi 可能没开，或当前没有连接到任何网络。")
                }
            }
        }
    }

    /// 信号格：实心/空心分开画，比 4 个 Image 切换更稳
    private var signalBars: some View {
        HStack(spacing: 3) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i <= model.wifiBars ? Theme.ok : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: CGFloat(6 + i * 4))
            }
        }
    }

    /// 按 dBm 给一句人话。-70 附近是"能用但别指望快"的分界
    private var signalHint: some View {
        let bars = model.wifiBars
        let text: String
        let color: Color
        switch bars {
        case 4:      text = "信号很好";   color = Theme.ok
        case 3:      text = "信号良好";   color = Theme.ok
        case 2:      text = "信号一般";   color = Theme.warn
        default:     text = "信号较弱";   color = Theme.bad
        }
        return Pill(text: text, color: color,
                    icon: bars >= 3 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
    }

    // MARK: 已保存的网络

    private var savedCard: some View {
        Card(title: "已保存的网络", subtitle: "点一下切换，不用输密码") {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                if model.wifiSaved.isEmpty {
                    EmptyState(icon: "wifi.exclamationmark",
                               title: "没有读到已保存的网络",
                               message: "先在系统菜单栏的 Wi-Fi 里连过一次，之后这里就能一键切换。")
                } else {
                    ForEach(model.wifiSaved, id: \.self) { ssid in
                        HStack(spacing: Theme.gapS) {
                            Image(systemName: "wifi")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(ssid)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if model.wifiJoining == ssid {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("连接") { model.wifiJoin(ssid) }
                                    .buttonStyle(.link)
                                    .disabled(!model.wifiJoining.isEmpty)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Divider().padding(.vertical, Theme.gapXS)

                HStack(spacing: Theme.gapS) {
                    LoadingButton(title: "逐个试连，找能上网的",
                                  icon: "arrow.triangle.2.circlepath",
                                  loading: model.wifiLoading) {
                        model.wifiTryAll()
                    }
                    .disabled(model.wifiSaved.isEmpty)
                    Button("刷新列表") { model.loadWifi() }
                        .buttonStyle(.borderless)
                }

                if !model.wifiMessage.isEmpty {
                    Text(model.wifiMessage)
                        .font(.callout)
                        .foregroundStyle(model.wifiMessage.contains("失败") || model.wifiMessage.contains("❌")
                                         ? Theme.bad : Theme.ok)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 自动切换

    private var autoCard: some View {
        Card(title: "自动切换", subtitle: "上不了网时自己换一个") {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                Toggle("Wi-Fi 上不了网时，自动切换到其它已保存的网络",
                       isOn: Binding(
                        get: { model.wifiFailoverOn },
                        set: { model.setWifiFailover(on: $0) }))
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 2) {
                    Text("优先尝试（逗号分隔，靠前优先）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Theme.gapS) {
                        TextField("留空 = 按系统保存顺序", text: $model.wifiPreferred)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                        Button("保存") { model.saveWifiPreferred() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(model.wifiLoading)
                    }
                }

                if !model.wifiPreferred.isEmpty {
                    HStack(spacing: Theme.gapXS) {
                        Image(systemName: "arrow.up.forward").font(.caption2)
                        Text("会先试：\(model.wifiPreferred)")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                Divider().padding(.vertical, Theme.gapXS)

                HStack(spacing: Theme.gapXS) {
                    Image(systemName: "shield.checkered").font(.caption)
                    Text("触发条件很严：Wi-Fi 和以太网都上不了网、且距上次尝试超过 2 分钟才会动。"
                         + "只会连「已保存过」的网络，不会碰你手动指定的有线优先。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 说明

    private var explainCard: some View {
        Card(title: "为什么看不到「附近的网络」？") {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                Label("macOS 要「定位服务」权限才肯把附近 Wi-Fi 的名字给应用。",
                      systemImage: "location.slash")
                Label("这个工具不为看扫描结果去要定位权限，所以只显示你保存过的网络。",
                      systemImage: "key")
                Label("要连新网络：点屏幕右上角菜单栏的 Wi-Fi 图标连一次，之后这里就能一键切。",
                      systemImage: "menubar.rectangle")
                Label("自动切换不需要密码——已保存网络的密码在系统钥匙串里。",
                      systemImage: "lock.shield")

                Text("终端里也可以：smartroute wifi list / join <网络名> / tryall / auto on")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, Theme.gapXS)
            }
            .font(.callout)
        }
    }
}

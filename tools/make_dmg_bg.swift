// make_dmg_bg.swift —— 生成 DMG 背景图（逻辑尺寸 1200x720，实际输出 2400x1440 适配视网膜）
// 编译: swiftc -O make_dmg_bg.swift -o make_dmg_bg
// 运行: ./make_dmg_bg dmg_bg.png
import AppKit

let W: CGFloat = 1200, H: CGFloat = 720
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()

// ---- 背景：淡蓝渐变 ----
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.965, green: 0.976, blue: 0.996, alpha: 1.0),
    NSColor(calibratedRed: 0.906, green: 0.937, blue: 0.988, alpha: 1.0)
])!
grad.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// ---- 顶部品牌条 ----
let barH: CGFloat = 96
NSColor(calibratedRed: 0.20, green: 0.58, blue: 1.00, alpha: 1.0).setFill()
NSRect(x: 0, y: H - barH, width: W, height: barH).fill()

func text(_ s: String, _ size: CGFloat, _ color: NSColor, _ x: CGFloat, _ y: CGFloat,
          _ w: CGFloat = W, align: NSTextAlignment = .left, bold: Bool = true) {
    let st = NSMutableParagraphStyle(); st.alignment = align
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular),
        .foregroundColor: color,
        .paragraphStyle: st
    ]
    (s as NSString).draw(in: NSRect(x: x, y: y, width: w, height: size * 2), withAttributes: attrs)
}

text("SmartRoute \(ProcessInfo.processInfo.environment["SR_VERSION"] ?? "2.2")", 44, .white, 48, H - barH + 28)
text("Mac 双网智能选路工具", 20, NSColor.white.withAlphaComponent(0.85), 48, H - barH + 4, bold: false)

// ---- 中部提示：把 App 拖到 Applications ----
text("把 SmartRoute 拖到 Applications 完成安装", 34,
     NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.24, alpha: 1.0), 0, H * 0.42,
     W, align: .center)

// ---- 箭头：从左侧 App 位置指向右侧 Applications ----
let arrow = NSBezierPath()
let ay = H * 0.30
arrow.move(to: NSPoint(x: W * 0.34, y: ay))
arrow.line(to: NSPoint(x: W * 0.62, y: ay))
NSColor(calibratedRed: 0.20, green: 0.58, blue: 1.00, alpha: 1.0).setStroke()
arrow.lineWidth = 7
arrow.lineCapStyle = .round
arrow.stroke()
// 箭头头部
let head = NSBezierPath()
head.move(to: NSPoint(x: W * 0.62, y: ay + 20))
head.line(to: NSPoint(x: W * 0.62 + 34, y: ay))
head.line(to: NSPoint(x: W * 0.62, y: ay - 20))
NSColor(calibratedRed: 0.20, green: 0.58, blue: 1.00, alpha: 1.0).setFill()
head.fill()

// ---- 底部小字 ----
text("首次打开如被 Gatekeeper 拦截：右键 → 打开（详见随附《安装说明.txt》）", 19,
     NSColor(calibratedRed: 0.42, green: 0.46, blue: 0.55, alpha: 1.0), 0, 26,
     W, align: .center, bold: false)

img.unlockFocus()
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(("PNG 生成失败\n" as NSString).data(using: String.Encoding.utf8.rawValue)!)
    exit(1)
}
do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
catch { print("写入失败: \(error)"); exit(1) }
print("已生成 \(CommandLine.arguments[1])")

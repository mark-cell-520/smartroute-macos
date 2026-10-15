// make_icon.swift —— 生成 SmartRoute 应用图标（1024x1024 PNG）
// 编译: swiftc -O make_icon.swift -o make_icon
// 运行: ./make_icon icon_1024.png
import AppKit

var S: CGFloat = 1024
if CommandLine.arguments.count > 2, let sz = Double(CommandLine.arguments[2]) { S = CGFloat(sz) }
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// ---- 背景：圆角矩形 + 渐变 ----
let bgRect = NSRect(x: 0, y: 0, width: S, height: S)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: S * 0.225, yRadius: S * 0.225)
let top = NSColor(calibratedRed: 0.20, green: 0.58, blue: 1.00, alpha: 1.0)
let bottom = NSColor(calibratedRed: 0.42, green: 0.28, blue: 0.98, alpha: 1.0)
let grad = NSGradient(colors: [top, bottom])!
grad.draw(in: bgPath, angle: -90)

// ---- 高光（顶部淡淡的亮带）----
let gloss = NSBezierPath(roundedRect: NSRect(x: 0, y: S * 0.62, width: S, height: S * 0.38),
                         xRadius: S * 0.225, yRadius: S * 0.225)
NSColor(white: 1.0, alpha: 0.10).setFill()
gloss.fill()

// ---- 图案：一条主干分叉成两条支路（象征双路选路）----
NSColor.white.setStroke()

func stroke(_ path: NSBezierPath, width: CGFloat, alpha: CGFloat = 1.0) {
    NSColor.white.withAlphaComponent(alpha).setStroke()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

let cx = S * 0.5
let trunk = NSBezierPath()
trunk.move(to: NSPoint(x: cx, y: S * 0.20))
trunk.line(to: NSPoint(x: cx, y: S * 0.46))
stroke(trunk, width: S * 0.062)

// 左支（Wi-Fi）
let left = NSBezierPath()
left.move(to: NSPoint(x: cx, y: S * 0.46))
left.curve(to: NSPoint(x: S * 0.24, y: S * 0.60),
           controlPoint1: NSPoint(x: cx - S * 0.02, y: S * 0.53),
           controlPoint2: NSPoint(x: S * 0.32, y: S * 0.585))
stroke(left, width: S * 0.062)

// 右支（以太网）
let right = NSBezierPath()
right.move(to: NSPoint(x: cx, y: S * 0.46))
right.curve(to: NSPoint(x: S * 0.76, y: S * 0.60),
            controlPoint1: NSPoint(x: cx + S * 0.02, y: S * 0.53),
            controlPoint2: NSPoint(x: S * 0.68, y: S * 0.585))
stroke(right, width: S * 0.062)

// ---- 端点圆点 ----
func dot(_ center: NSPoint, r: CGFloat, alpha: CGFloat) {
    let d = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    NSColor.white.withAlphaComponent(alpha).setFill()
    d.fill()
}
dot(NSPoint(x: cx, y: S * 0.20), r: S * 0.055, alpha: 1.0)
dot(NSPoint(x: S * 0.24, y: S * 0.60), r: S * 0.058, alpha: 1.0)
dot(NSPoint(x: S * 0.76, y: S * 0.60), r: S * 0.058, alpha: 1.0)

// ---- 左端点画 Wi-Fi 弧线，右端点画 RJ45 方块 ----
let wifiC = NSPoint(x: S * 0.24, y: S * 0.60)
for i in 0..<3 {
    let r = S * (0.052 + 0.042 * CGFloat(i))
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: wifiC.x, y: wifiC.y - S * 0.035),
                  radius: r, startAngle: 35, endAngle: 145, clockwise: false)
    stroke(arc, width: S * 0.030, alpha: 0.95 - 0.2 * CGFloat(i))
}
let ethC = NSPoint(x: S * 0.76, y: S * 0.60)
let sq = NSBezierPath(roundedRect: NSRect(x: ethC.x - S * 0.055, y: ethC.y - S * 0.028,
                                          width: S * 0.11, height: S * 0.056),
                      xRadius: S * 0.016, yRadius: S * 0.016)
stroke(sq, width: S * 0.028, alpha: 0.95)

// ---- 底部速度条（象征并发流量）----
let barW = S * 0.055
let gap = S * 0.022
let baseY = S * 0.80
let heights: [CGFloat] = [0.045, 0.075, 0.10, 0.065, 0.09, 0.055]
for (i, h) in heights.enumerated() {
    let x = cx - (CGFloat(heights.count) * (barW + gap) - gap) / 2 + CGFloat(i) * (barW + gap)
    let bar = NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barW, height: S * h),
                           xRadius: barW / 2, yRadius: barW / 2)
    NSColor.white.withAlphaComponent(0.55 + 0.08 * CGFloat(i)).setFill()
    bar.fill()
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG 生成失败\n".data(using: .utf8)!)
    exit(1)
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
do {
    try data.write(to: URL(fileURLWithPath: out))
    print("已生成 \(out) (\(data.count) bytes)")
} catch {
    FileHandle.standardError.write("写入失败: \(error)\n".data(using: .utf8)!)
    exit(1)
}

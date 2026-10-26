// make_dmg_background.swift
// 生成 dmg 安装窗口的背景图（浅色渐变 + 指向右方的箭头 + 中文提示）
// 用法: swift packaging/make_dmg_background.swift packaging/dmg-background.png
//
// 布局约定（与 packaging/dmg.dsstore 中的图标位置保持一致，单位 pt，原点左上）：
//   cute pet.app 图标中心 (165, 210)   Applications 图标中心 (495, 210)
//   窗口内容区 660 x 420

import AppKit

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "dmg-background.png"

let width: CGFloat = 660
let height: CGFloat = 420
let scale: CGFloat = 2

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width * scale),
    pixelsHigh: Int(height * scale),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("无法创建位图缓冲")
}
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// AppKit 绘图原点在左下角；用 top(_:) 把「从顶部量」的坐标换算过来
func top(_ y: CGFloat) -> CGFloat { height - y }

// ── 背景渐变 ─────────────────────────────────────────────
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.980, green: 0.984, blue: 0.996, alpha: 1.0),
    NSColor(srgbRed: 0.906, green: 0.933, blue: 0.973, alpha: 1.0),
])
gradient?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

// ── 居中绘制一行文字 ──────────────────────────────────────
func drawCentered(_ text: String, font: NSFont, color: NSColor, centerAtTop y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: text, attributes: attrs)
    let size = str.size()
    let rect = NSRect(
        x: (width - size.width) / 2,
        y: top(y) - size.height / 2,
        width: size.width,
        height: size.height
    )
    str.draw(in: rect)
}

// ── 标题与底部提示 ───────────────────────────────────────
drawCentered(
    "把 cute pet 拖进「应用程序」",
    font: .systemFont(ofSize: 17, weight: .semibold),
    color: NSColor(srgbRed: 0.224, green: 0.271, blue: 0.341, alpha: 1.0),
    centerAtTop: 52
)
drawCentered(
    "装好后在访达侧栏点 ⏏ 弹出；首次打开若被拦截，右键点图标选「打开」",
    font: .systemFont(ofSize: 11.5, weight: .regular),
    color: NSColor(srgbRed: 0.475, green: 0.529, blue: 0.608, alpha: 1.0),
    centerAtTop: 372
)

// ── 中间的大箭头（从 cute pet 指向 Applications）─────────────
let arrowColor = NSColor(srgbRed: 0.412, green: 0.525, blue: 0.678, alpha: 1.0)
let midY = top(210)
let startX: CGFloat = 250
let headTipX: CGFloat = 412
let headLength: CGFloat = 26
let headHalfHeight: CGFloat = 17
let shaftHeight: CGFloat = 9

arrowColor.setFill()
let shaft = NSBezierPath(roundedRect: NSRect(
    x: startX,
    y: midY - shaftHeight / 2,
    width: headTipX - headLength - startX + 4,
    height: shaftHeight
), xRadius: shaftHeight / 2, yRadius: shaftHeight / 2)
shaft.fill()

let head = NSBezierPath()
head.move(to: NSPoint(x: headTipX, y: midY))
head.line(to: NSPoint(x: headTipX - headLength, y: midY + headHalfHeight))
head.line(to: NSPoint(x: headTipX - headLength, y: midY - headHalfHeight))
head.close()
head.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG 编码失败")
}
try png.write(to: URL(fileURLWithPath: outPath))
print("✅ 已生成 \(outPath)（\(rep.pixelsWide)x\(rep.pixelsHigh)）")

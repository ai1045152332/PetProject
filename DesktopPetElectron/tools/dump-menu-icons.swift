// DesktopPetElectron/tools/dump-menu-icons.swift
// 生成 mac 顶栏「整条状态项」瓦片：Electron 的 tray.setTitle 只收纯字符串，塞不进
// Swift 那套 NSAttributedString + SF Symbol 图片附件，所以把图标和数字离线导成
// 「纯黑 + alpha」PNG 瓦片，由 src/main/metric-bar-image.js 拼成一张模板图走 tray.setImage。
//
// 规格全部照抄 Swift 侧 App/DesktopPetForMacAppApp.swift：
//   字体 NSFont.systemFont(ofSize: 12)、符号 SymbolConfiguration(pointSize: 12, weight: .medium)、
//   附件框 14×13 且底边落在基线下 2pt（buildMetricTitle 的 att.bounds = (0,-2,14,13)）。
// 每张瓦片都是 22pt 高（= 菜单栏可视高）的整条切片，横向按「字宽 advance」裁切，
// 于是拼接侧只需要从左到右依次 blit、不需要任何基线运算。
//
// 为什么仓库里要留这个脚本（与 WindowsTray 描边图「不留派生脚本」的约定相反）：
// SF Symbol 的形状与系统字体由 macOS 版本决定，会随系统升级变；不留脚本就无法跟随重导。
//
// 用法：xcrun swift DesktopPetElectron/tools/dump-menu-icons.swift [输出目录]
// 默认输出 DesktopPetElectron/../SharedAssets/menu-icons
// 产物：<key>.1x.png + <key>.2x.png + manifest.json（瓦片点宽、条高、基线，供 JS 校验）
import AppKit
import CoreGraphics
import CoreText
import Foundation

let stripH = 22                    // 菜单栏可视高（pt），Swift 侧 btn.image 也是 22×22
let symbolW: CGFloat = 14, symbolH: CGFloat = 13, symbolDrop: CGFloat = 2
let pointSize: CGFloat = 12

// 指标键 → SF Symbol 名（与 Swift refreshMenuBarMetrics 的 symbol 列表一一对应）
let symbolTiles: [(key: String, symbol: String)] = [
    ("cpu", "cpu"),
    ("mem", "memorychip"),
    ("disk", "internaldrive"),
    ("net", "arrow.up.arrow.down"),
]
// 顶栏数值串里会出现的字符 → 瓦片键（Swift 的格式：整数%、整数K/整数K，以及指标间一个空格）
let glyphTiles: [(key: String, ch: String)] = [
    ("g-0", "0"), ("g-1", "1"), ("g-2", "2"), ("g-3", "3"), ("g-4", "4"),
    ("g-5", "5"), ("g-6", "6"), ("g-7", "7"), ("g-8", "8"), ("g-9", "9"),
    ("g-pct", "%"), ("g-K", "K"), ("g-slash", "/"), ("g-space", " "),
]

let args = CommandLine.arguments
let fm = FileManager.default
let repoRoot = fm.currentDirectoryPath.hasSuffix("DesktopPetElectron/tools")
    ? fm.currentDirectoryPath.replacingOccurrences(of: "/DesktopPetElectron/tools", with: "")
    : fm.currentDirectoryPath
let outDir = args.count > 1 ? args[1] : "\(repoRoot)/SharedAssets/menu-icons"
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let font = NSFont.systemFont(ofSize: pointSize)
let ascent = font.ascender, descent = -font.descender
// 文本在 22pt 条里垂直居中（原生菜单栏就是把标题垂直居中的）
let baselineFromTop = (CGFloat(stripH) - (ascent + descent)) / 2 + ascent
// 符号框顶边 = 基线 - (框高 - 下沉)，与 Swift 的 att.bounds.y = -2 等价
let symbolTopFromTop = baselineFromTop - (symbolH - symbolDrop)

let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: NSFont.Weight.medium)

/// 单字符总推进宽度（size(withAttributes:) 会吃掉尾部空白，空格瓦片必须用字形 advance）
func advanceOf(_ ch: String) -> CGFloat {
    guard let code = ch.utf16.first else { return 0 }
    var glyph = CGGlyph()
    let chars = [code]
    guard CTFontGetGlyphsForCharacters(font as CTFont, chars, &glyph, 1) else { return 0 }
    var adv = CGSize.zero
    CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, &glyph, &adv, 1)
    return adv.width
}

/// 在 scale 倍分辨率的位图 rep 里按点坐标绘制（AppKit 会自动选合适的 rep 栅格化，符号与文字都是矢量级清晰）
func renderTile(widthPt: Int, scale: Int, draw: () -> Void) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: widthPt * scale, pixelsHigh: stripH * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: widthPt * scale * 4, bitsPerPixel: 32) else { return nil }
    rep.size = NSSize(width: widthPt, height: stripH)
    guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    draw()
    gctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    // 归一成「rgb 全黑 + alpha 形状」：模板图只看 alpha，带色渲染时取亮度当 alpha
    guard let data = rep.bitmapData, let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: widthPt * scale, pixelsHigh: stripH * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: widthPt * scale * 4, bitsPerPixel: 32),
        let o = out.bitmapData else { return nil }
    out.size = rep.size
    let n = widthPt * scale * stripH * scale
    for i in 0..<n {
        let r = data[i * 4], g = data[i * 4 + 1], b = data[i * 4 + 2], a = data[i * 4 + 3]
        o[i * 4] = 0
        o[i * 4 + 1] = 0
        o[i * 4 + 2] = 0
        o[i * 4 + 3] = (r == 0 && g == 0 && b == 0) ? a : max(r, max(g, b))
    }
    return out.representation(using: .png, properties: [:])
}

var manifest: [String: Any] = [
    "stripHeight": stripH,
    "baselineFromTop": (baselineFromTop * 100).rounded() / 100,
    "tiles": [String: Any](),
]
var tiles = [String: [String: Any]]()
var failed: [String] = []

for (key, symbol) in symbolTiles {
    guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { failed.append(symbol); continue }
    let w = Int(symbolW)
    for scale in [1, 2] {
        let rect = NSRect(x: 0, y: CGFloat(stripH) - symbolTopFromTop - symbolH, width: symbolW, height: symbolH)
        guard let png = renderTile(widthPt: w, scale: scale, draw: {
            base.draw(in: rect, from: NSRect.zero, operation: NSCompositingOperation.sourceOver, fraction: 1.0)
        }) else { failed.append("\(key)@\(scale)x"); continue }
        try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(key).\(scale)x.png"))
    }
    tiles[key] = ["w": w, "kind": "symbol", "symbol": symbol]
}

for (key, ch) in glyphTiles {
    let w = max(1, Int(ceil(advanceOf(ch))))
    for scale in [1, 2] {
        guard let png = renderTile(widthPt: w, scale: scale, draw: {
            (ch as NSString).draw(
                at: NSPoint(x: 0, y: CGFloat(stripH) - baselineFromTop),
                withAttributes: [.font: font, .foregroundColor: NSColor.black])
        }) else { failed.append("\(key)@\(scale)x"); continue }
        try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(key).\(scale)x.png"))
    }
    tiles[key] = ["w": w, "kind": "glyph", "char": ch]
}

manifest["tiles"] = tiles
let json = try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
try? json.write(to: URL(fileURLWithPath: "\(outDir)/manifest.json"))

print("基线距顶 \(String(format: "%.2f", baselineFromTop))pt（ascent \(ascent) / descent \(descent)），符号框顶距顶 \(String(format: "%.2f", symbolTopFromTop))pt")
for (key, v) in tiles.sorted(by: { $0.key < $1.key }) {
    print("✓ \(key) w=\(v["w"] ?? -1)")
}
print("输出目录：\(outDir)，瓦片 \(tiles.count) 张")
if !failed.isEmpty {
    print("✗ 渲染失败：\(failed.joined(separator: ", "))")
    exit(1)
}

// DesktopPetElectron/tools/dump-menu-icons.swift
// 生成 mac 顶栏指标图标瓦片：把 SF Symbol 按 Swift 侧 buildMetricTitle 的同一套配置
// （pointSize 12 / weight .medium / 14×13 pt）导出成「纯黑 + alpha」PNG，
// 落到仓库根 SharedAssets/menu-icons/，供 Electron 合成整条状态项模板图。
//
// 为什么仓库里要留这个脚本（与 WindowsTray 描边图「不留派生脚本」的约定相反）：
// SF Symbol 的形状由系统字体决定，会随 macOS 版本变；不留脚本就无法跟随重导。
//
// 用法：xcrun swift DesktopPetElectron/tools/dump-menu-icons.swift [输出目录]
// 默认输出 DesktopPetElectron/../SharedAssets/menu-icons
import AppKit
import CoreGraphics
import Foundation

// 与 Swift 版 App/DesktopPetForMacAppApp.swift buildMetricTitle 的 symbol 列表一一对应
let symbols = ["cpu", "memorychip", "internaldrive", "arrow.up.arrow.down"]
let pointSize: CGFloat = 12
let weight = NSImage.SymbolWeight.medium
let wPt = 14.0, hPt = 13.0   // attachment bounds 的宽高，照抄 Swift

let args = CommandLine.arguments
let fm = FileManager.default
let repoRoot = fm.currentDirectoryPath.hasSuffix("DesktopPetElectron/tools")
    ? fm.currentDirectoryPath.replacingOccurrences(of: "/DesktopPetElectron/tools", with: "")
    : fm.currentDirectoryPath
let outDir = args.count > 1 ? args[1] : "\(repoRoot)/SharedAssets/menu-icons"
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)

/// 按 scale 渲染成「纯黑 + alpha」位图像节；symbol 不可用时返回 nil
func render(_ name: String, _ scale: Int) -> (Data, Int, Int)? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return nil }
    let w = Int(wPt * CGFloat(scale)), h = Int(hPt * CGFloat(scale))
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
    var rect = CGRect(x: 0, y: 0, width: w, height: h)
    let hints: [NSImageRep.HintKey: Any]? = nil
    let gctx: NSGraphicsContext? = nil
    if let cg = base.cgImage(forProposedRect: &rect, context: gctx, hints: hints) {
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    guard let src = ctx.data, let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32) else { return nil }
    let p = src.bindMemory(to: UInt8.self, capacity: w * h * 4)
    guard let o = rep.bitmapData else { return nil }
    for i in 0..<(w * h) {
        // 已实测 symbol 直接画出来就是 rgb 全黑、只有 alpha；再兜一道保证万一是带色渲染时取亮度当 alpha
        let r = p[i * 4], g = p[i * 4 + 1], b = p[i * 4 + 2], a = p[i * 4 + 3]
        let lum = max(r, max(g, b))
        o[i * 4] = 0
        o[i * 4 + 1] = 0
        o[i * 4 + 2] = 0
        o[i * 4 + 3] = (r == 0 && g == 0 && b == 0) ? a : lum
    }
    return (rep.representation(using: .png, properties: [:]) ?? Data(), w, h)
}

var failed: [String] = []
for name in symbols {
    for scale in [1, 2] {
        guard let (png, w, h) = render(name, scale) else { failed.append("\(name)@\(scale)x"); continue }
        let file = scale == 1 ? "\(outDir)/\(name).png" : "\(outDir)/\(name}@2x.png"
        try? png.write(to: URL(fileURLWithPath: file))
        print("✓ \(name)@\(scale)x → \(w)x\(h)")
    }
}
if !failed.isEmpty {
    print("✗ 渲染失败：\(failed.joined(separator: ", "))")
    exit(1)
}
print("输出目录：\(outDir)")

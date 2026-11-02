// out/probe-symbol.swift —— 探测：SF Symbol 能否导出成「纯黑 + alpha」模板瓦片
// 规格照抄 Swift 侧 buildMetricTitle：pointSize 12 / weight .medium / 14×13 pt
import AppKit
import CoreGraphics

let names = ["cpu", "memorychip", "internaldrive", "arrow.up.arrow.down"]
let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
let scale = 2            // 先只出 @2x，看像素分布
let wPt = 14, hPt = 13
let w = wPt * scale, h = hPt * scale

for name in names {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else {
        print("\(name): SYMBOL_UNAVAILABLE"); continue
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("\(name): CTX_FAIL"); continue
    }
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
    var rect = CGRect(x: 0, y: 0, width: w, height: h)
    if let cg = base.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    guard let data = ctx.data else { print("\(name): NO_DATA"); continue }
    let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var opaque = 0, colored = 0, alphaOnly = 0
    var maxA = 0, sampleRGBA: [UInt8] = [0, 0, 0, 0]
    for i in 0..<(w * h) {
        let r = p[i * 4], g = p[i * 4 + 1], b = p[i * 4 + 2], a = p[i * 4 + 3]
        if a > 0 {
            opaque += 1
            maxA = max(maxA, Int(a))
            if r != 0 || g != 0 || b != 0 { colored += 1 }
            else { alphaOnly += 1 }
            if a > 200 && sampleRGBA[3] == 0 { sampleRGBA = [r, g, b, a] }
        }
    }
    print("\(name): 尺寸 \(w)x\(h) 有像素 \(opaque) / \(w * h)，其中 rgb 全黑(alpha 形状)=\(alphaOnly)，带颜色=\(colored)，最大 alpha=\(maxA)，样本 RGBA=\(sampleRGBA)")
}

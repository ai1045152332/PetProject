// SkinManager.swift
// DesktopPetForMacApp — 宠物皮肤包：照片 → Vision 抠图 → 按状态目录生成各状态帧
// 零模型依赖：macOS 14+ 用 VNGenerateForegroundInstanceMaskRequest 主体抠图，
// macOS 13 降级用 VNGenerateAttentionBasedSaliencyImageRequest 显著性图生成 alpha。
// 生成结果按文档状态目录结构保存：
//   Application Support/<bundle>/Skins/{focus,idel,warn,sleep,pet}/frame_00.png … frame_07.png
// 每个状态 8 帧（12fps 循环），由程序化变换生成，无需扩散模型：
//   idel   休闲：呼吸缩放（±3%）
//   sleep  睡觉：压暗 + 蜷缩 + 缓慢浮沉
//   warn   提醒：暖红染色 + 水平抖动
//   pet    抚摸：上下轻弹
//   focus  专注：几乎静止

import AppKit
import Vision
import CoreImage

enum SkinError: LocalizedError {
    case cannotReadImage
    case noSubject
    case extractFailed

    var errorDescription: String? {
        switch self {
        case .cannotReadImage: return "无法读取所选图片"
        case .noSubject: return "未识别到主体，请换一张背景简洁、主体清晰的照片"
        case .extractFailed: return "主体提取失败，请换一张照片重试"
        }
    }
}

@MainActor
final class SkinManager {

    // MARK: - 存储

    /// 皮肤包根目录：Application Support/<bundle>/Skins/
    /// nonisolated：纯路径计算，供 SpriteSheet 等非主线程隔离上下文使用
    nonisolated static var skinsDirectory: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? "DesktopPetForMacApp"
        return appSupport
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("Skins", isDirectory: true)
    }

    /// 某状态的帧目录（Skins/<state>/）
    nonisolated static func frameDirectory(for state: CatAnimationState) -> URL? {
        guard let root = skinsDirectory else { return nil }
        return root.appendingPathComponent(state.rawValue, isDirectory: true)
    }

    /// 皮肤变更通知（设置面板刷新 UI，PetViewModel 重载精灵）
    static let skinChangedNotification = Notification.Name("SkinManager.skinChanged")

    /// 皮肤包是否存在（任一状态目录下有 PNG 帧即视为存在）
    /// nonisolated：纯文件检查，供非主线程隔离上下文使用
    nonisolated static var hasSkin: Bool {
        guard let root = skinsDirectory else { return false }
        let fm = FileManager.default
        for state in CatAnimationState.allCases {
            let dir = root.appendingPathComponent(state.rawValue)
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            if files.contains(where: { $0.lowercased().hasSuffix(".png") }) { return true }
        }
        return false
    }

    // MARK: - 操作

    /// 弹窗选照片 → 抠图 → 按状态生成帧包 → 通知
    static func pickAndGenerateSkin(completion: @escaping (Result<NSImage, Error>) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "选择宠物照片（背景简洁、主体清晰效果最好）"
        panel.message = "照片只在本地处理，不会上传"
        panel.allowedFileTypes = ["png", "jpg", "jpeg", "heic", "tiff"]
        panel.allowsMultipleSelection = false
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else {
                completion(.failure(SkinError.cannotReadImage))
                return
            }
            generateSkin(from: url, completion: completion)
        }
    }

    /// 从文件生成皮肤包（全局队列跑抠图+帧生成，主线程回调）
    static func generateSkin(from url: URL, completion: @escaping (Result<NSImage, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let img = NSImage(contentsOf: url),
                      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw SkinError.cannotReadImage
                }
                // 降采样到最长边 1024，兼顾清晰度与抠图速度
                let working = downsample(cgImage: cg, maxSide: 1024)
                let foreground = try extractForeground(cgImage: working)
                try generateStateFrames(foreground: foreground)

                let result = NSImage(cgImage: foreground, size: NSSize(width: foreground.width, height: foreground.height))
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: skinChangedNotification, object: nil)
                    completion(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// 清除皮肤包（删除整个 Skins 目录）
    static func clearSkin() {
        guard let root = skinsDirectory else { return }
        try? FileManager.default.removeItem(at: root)
        NotificationCenter.default.post(name: skinChangedNotification, object: nil)
    }

    // MARK: - 按状态目录生成帧

    /// 每个状态的程序化动画参数
    private struct StateAnim {
        let state: CatAnimationState
        let baseScale: CGFloat  // 相对主体原始尺寸的基准缩放（sleep 蜷缩）
        let breatheAmp: CGFloat // 呼吸缩放幅度（相对）
        let dxAmp: CGFloat      // 水平抖动幅度（相对画布边长）
        let dyAmp: CGFloat      // 上下浮沉幅度（相对画布边长，负值向下）
        let dim: CGFloat        // 压暗强度 0~1
        let warm: CGFloat       // 暖色染色强度 0~1
    }

    private static let stateAnims: [StateAnim] = [
        StateAnim(state: .idel,  baseScale: 1.00, breatheAmp: 0.035, dxAmp: 0.0,    dyAmp: 0.0,    dim: 0.0,  warm: 0.0),
        StateAnim(state: .sleep, baseScale: 0.93, breatheAmp: 0.012, dxAmp: 0.0,    dyAmp: 0.006,  dim: 0.30, warm: 0.0),
        StateAnim(state: .warn,  baseScale: 1.00, breatheAmp: 0.015, dxAmp: 0.012,  dyAmp: 0.0,    dim: 0.0,  warm: 0.45),
        StateAnim(state: .pet,   baseScale: 0.97, breatheAmp: 0.020, dxAmp: 0.0,    dyAmp: 0.020,  dim: 0.0,  warm: 0.0),
        StateAnim(state: .focus, baseScale: 1.00, breatheAmp: 0.008, dxAmp: 0.0,    dyAmp: 0.0,    dim: 0.0,  warm: 0.0),
    ]

    /// 帧数（12fps 循环）
    static let framesPerState = 8

    /// 为每个状态生成 8 帧 PNG 到 Skins/<state>/frame_00..07.png
    private static func generateStateFrames(foreground: CGImage) throws {
        guard let root = skinsDirectory else { throw SkinError.extractFailed }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // 统一正方形画布：边长 = 主体长边 × 1.12，主体 aspect-fit 占画布 88%（呼吸/抖动不越界）
        let fw = foreground.width
        let fh = foreground.height
        let canvas = max(64, Int(ceil(CGFloat(max(fw, fh)) * 1.12)))
        guard let colorSpace = foreground.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SkinError.extractFailed
        }
        let baseScale = (CGFloat(canvas) * 0.88) / CGFloat(max(fw, fh))

        for anim in stateAnims {
            let dir = root.appendingPathComponent(anim.state.rawValue, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            for i in 0..<framesPerState {
                let phase = CGFloat(i) * 2.0 * .pi / CGFloat(framesPerState)
                let scale = baseScale * anim.baseScale * (1.0 + anim.breatheAmp * sin(phase))
                let w = CGFloat(fw) * scale
                let h = CGFloat(fh) * scale
                let dx = CGFloat(canvas) * anim.dxAmp * sin(phase)
                let dy = CGFloat(canvas) * anim.dyAmp * sin(phase + .pi / 2.0)
                let rect = CGRect(x: (CGFloat(canvas) - w) / 2.0 + dx,
                                  y: (CGFloat(canvas) - h) / 2.0 + dy,
                                  width: w, height: h)

                guard let ctx = CGContext(data: nil, width: canvas, height: canvas,
                                          bitsPerComponent: 8, bytesPerRow: canvas * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw SkinError.extractFailed
                }
                ctx.interpolationQuality = .high
                ctx.draw(foreground, in: rect)

                // 状态染色：sourceAtop 只作用于已有像素，透明区域不受污染
                if anim.dim > 0 || anim.warm > 0 {
                    ctx.saveGState()
                    ctx.setBlendMode(.sourceAtop)
                    if anim.dim > 0 {
                        ctx.setFillColor(NSColor.black.withAlphaComponent(anim.dim * 0.55).cgColor)
                        ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
                    }
                    if anim.warm > 0 {
                        ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.2, alpha: anim.warm * 0.35).cgColor)
                        ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
                    }
                    ctx.restoreGState()
                }

                guard let frame = ctx.makeImage() else { throw SkinError.extractFailed }
                let url = dir.appendingPathComponent(String(format: "frame_%02d.png", i))
                let rep = NSBitmapImageRep(cgImage: frame)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    throw SkinError.extractFailed
                }
                // 临时文件 + 原子替换，避免写一半
                let tmp = url.appendingPathExtension("tmp")
                try data.write(to: tmp)
                _ = try? fm.removeItem(at: url)
                try fm.moveItem(at: tmp, to: url)
            }
        }
    }

    // MARK: - 抠图

    /// 主体抠图：macOS 14+ 用实例分割；13 用显著性图
    private static func extractForeground(cgImage: CGImage) throws -> CGImage {
        if #available(macOS 14.0, *) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            guard let observation = request.results?.first else { throw SkinError.noSubject }
            // generateMaskedImage(ofInstances:from:croppedToInstancesExtent:) 返回透明背景（已预乘 alpha）的 CVPixelBuffer，失败抛错
            let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances,
                                                                    from: handler,
                                                                    croppedToInstancesExtent: true)
            let ci = CIImage(cvPixelBuffer: buffer)
            let ctx = CIContext(options: [.workingColorSpace: NSNull()])
            guard let cgOut = ctx.createCGImage(ci, from: ci.extent) else { throw SkinError.extractFailed }
            return cgOut
        } else {
            return try saliencyMatting(cgImage: cgImage)
        }
    }

    /// macOS 13 兜底：attention 显著性图（单通道 float）作 alpha，RGB 按 alpha 预乘
    private static func saliencyMatting(cgImage: CGImage) throws -> CGImage {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let saliency = request.results?.first as? VNSaliencyImageObservation else { throw SkinError.noSubject }

        let map = saliency.pixelBuffer
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let bpr = CVPixelBufferGetBytesPerRow(map)
        guard width > 0, height > 0,
              let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SkinError.extractFailed
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map)?.assumingMemoryBound(to: Float.self),
              let out = ctx.data?.assumingMemoryBound(to: UInt8.self) else {
            throw SkinError.extractFailed
        }

        let fpr = bpr / 4
        for y in 0..<height {
            let oRow = y * width * 4
            let sRow = y * fpr
            for x in 0..<width {
                let s = base[sRow + x]  // 0.0~1.0 float
                let a = Int(s * 255)
                let o = oRow + x * 4
                out[o + 0] = UInt8((Int(out[o + 0]) * a) >> 8)
                out[o + 1] = UInt8((Int(out[o + 1]) * a) >> 8)
                out[o + 2] = UInt8((Int(out[o + 2]) * a) >> 8)
                out[o + 3] = UInt8(a)
            }
        }
        guard let result = ctx.makeImage() else { throw SkinError.extractFailed }
        return result
    }

    // MARK: - 工具

    /// 按最长边降采样（保留透明通道）
    private static func downsample(cgImage: CGImage, maxSide: Int) -> CGImage {
        let w = cgImage.width
        let h = cgImage.height
        let maxDim = max(w, h)
        guard maxDim > maxSide else { return cgImage }
        let scale = CGFloat(maxSide) / CGFloat(maxDim)
        let tw = max(1, Int(CGFloat(w) * scale))
        let th = max(1, Int(CGFloat(h) * scale))
        guard let colorSpace = cgImage.colorSpace,
              let ctx = CGContext(data: nil, width: tw, height: th,
                                  bitsPerComponent: 8, bytesPerRow: tw * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return cgImage
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage() ?? cgImage
    }
}

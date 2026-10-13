// SpriteSheet.swift
// DesktopPetForMacApp — 精灵图帧加载器
// 支持两种资源布局：
//   1. 子文件夹模式（推荐）: Resources/Sprites/{state}/0.png, 1.png, ...
//   2. 扁平模式（SPM 兼容）: Resources/Sprites/{state}_0.png, {state}_1.png, ...

import AppKit

final class SpriteSheet {
    let state: CatAnimationState
    let frames: [NSImage]
    let frameCount: Int

    /// 从横向精灵图裁剪初始化（保留，暂未使用）
    init?(state: CatAnimationState,
          image: NSImage,
          frameCount: Int,
          frameSize: NSSize? = nil) {
        self.state = state
        self.frameCount = frameCount

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let totalWidth = CGFloat(cgImage.width)
        let totalHeight = CGFloat(cgImage.height)
        let size = frameSize ?? NSSize(
            width: totalWidth / CGFloat(frameCount),
            height: totalHeight
        )

        var extractedFrames: [NSImage] = []
        for i in 0..<frameCount {
            let rect = CGRect(
                x: CGFloat(i) * size.width,
                y: 0,
                width: size.width,
                height: size.height
            )
            guard let cropped = cgImage.cropping(to: rect) else { continue }
            extractedFrames.append(NSImage(cgImage: cropped, size: size))
        }

        guard !extractedFrames.isEmpty else { return nil }
        self.frames = extractedFrames
    }

    /// 自动扫描 PNG 帧
    /// 先尝试子文件夹模式，再回退到扁平前缀模式
    init?(state: CatAnimationState) {
        self.state = state

        let allDirs = Self.allPossibleDirs(for: state.rawValue)
        NSLog("[DesktopPetForMacApp] Scanning for state '%@'", state.rawValue)

        var loadedFrames: [NSImage] = []

        // 模式 1：子文件夹扫描 (Sprites/idle/*.png)
        for dir in allDirs {
            if let frames = Self.loadFramesFromDirectory(dir) {
                loadedFrames = frames
                NSLog("[DesktopPetForMacApp] ✓ Loaded %d frames from subfolder: %@", frames.count, dir.path)
                break
            }
        }

        // 模式 2：扁平前缀扫描 (Sprites/idle_*.png)
        if loadedFrames.isEmpty {
            let flatDirs = Self.allPossibleFlatDirs()
            for dir in flatDirs {
                if let frames = Self.loadFramesByPrefix(from: dir, prefix: state.rawValue) {
                    loadedFrames = frames
                    NSLog("[DesktopPetForMacApp] ✓ Loaded %d frames by prefix '%@_' from: %@", frames.count, state.rawValue, dir.path)
                    break
                }
            }
        }

        if loadedFrames.isEmpty {
            NSLog("[DesktopPetForMacApp] ✗ No frames found for %@, using placeholder", state.rawValue)
            loadedFrames = [SpriteSheet.placeholderImage(color: .orange, size: NSSize(width: 128, height: 128))]
        }

        self.frames = loadedFrames
        self.frameCount = loadedFrames.count
        NSLog("[DesktopPetForMacApp] Final frame count for %@: %d", state.rawValue, frameCount)
    }

    // MARK: - Loading Helpers

    /// 从目录扫描所有 PNG 文件（子文件夹模式）
    private static func loadFramesFromDirectory(_ dir: URL) -> [NSImage]? {
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }

        let pngFiles: [URL]
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            pngFiles = contents
                .filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return nil
        }

        guard !pngFiles.isEmpty else { return nil }

        var frames: [NSImage] = []
        for url in pngFiles {
            if let image = NSImage(contentsOf: url) {
                frames.append(image)
            }
        }
        return frames.isEmpty ? nil : frames
    }

    /// 从目录按前缀扫描文件（扁平模式）
    private static func loadFramesByPrefix(from dir: URL, prefix: String) -> [NSImage]? {
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }

        let prefixPattern = "\(prefix)_"

        let pngFiles: [URL]
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            pngFiles = contents
                .filter {
                    $0.pathExtension.lowercased() == "png" &&
                    $0.lastPathComponent.hasPrefix(prefixPattern)
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return nil
        }

        guard !pngFiles.isEmpty else { return nil }

        var frames: [NSImage] = []
        for url in pngFiles {
            if let image = NSImage(contentsOf: url) {
                frames.append(image)
            }
        }
        return frames.isEmpty ? nil : frames
    }

    // MARK: - Path Resolution

    /// 子文件夹模式的所有可能路径（不依赖 SPM bundle，纯文件系统）
    static func allPossibleDirs(for stateName: String) -> [URL] {
        var dirs: [URL] = []
        let fm = FileManager.default

        // 0. 皮肤包目录（最高优先级）：Skins/<state>/ — 用户照片生成的帧优先于内置精灵图
        if let skinsRoot = SkinManager.skinsDirectory {
            dirs.append(skinsRoot.appendingPathComponent(stateName, isDirectory: true))
        }

        // 1. Bundle.main (.app bundle) — 分发环境
        let mainBundle = Bundle.main
        if let url = mainBundle.resourceURL {
            dirs.append(url.appendingPathComponent("Sprites/\(stateName)"))
        }
        dirs.append(mainBundle.bundleURL.appendingPathComponent("Contents/Resources/Sprites/\(stateName)"))
        dirs.append(mainBundle.bundleURL.appendingPathComponent("Resources/Sprites/\(stateName)"))

        // 2. 可执行文件同级及上级目录
        if let execURL = Bundle.main.executableURL {
            var url = execURL.deletingLastPathComponent()
            // 同级
            dirs.append(url.appendingPathComponent("Sprites/\(stateName)"))
            dirs.append(url.appendingPathComponent("Resources/Sprites/\(stateName)"))
            // 上级（.app/Contents/MacOS/ → .app/Contents/）
            url = url.deletingLastPathComponent()
            dirs.append(url.appendingPathComponent("Resources/Sprites/\(stateName)"))
            // 再上两级（开发环境：.build/debug/ → 项目根目录）
            url = url.deletingLastPathComponent().deletingLastPathComponent()
            dirs.append(url.appendingPathComponent("DesktopPetForMacApp/Resources/Sprites/\(stateName)"))
            // 再上三级（debug/arm64-apple-macosx/ 的情况）
            url = url.deletingLastPathComponent()
            dirs.append(url.appendingPathComponent("DesktopPetForMacApp/Resources/Sprites/\(stateName)"))
        }

        // 3. 工作目录（swift run 时）
        dirs.append(URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("DesktopPetForMacApp/Resources/Sprites/\(stateName)"))

        return Self.deduplicate(dirs)
    }

    /// 扁平模式的所有可能目录（不含 state 子路径）
    static func allPossibleFlatDirs() -> [URL] {
        var dirs: [URL] = []
        let fm = FileManager.default

        // 1. Bundle.main
        let mainBundle = Bundle.main
        if let url = mainBundle.resourceURL {
            dirs.append(url)
        }
        dirs.append(mainBundle.bundleURL.appendingPathComponent("Contents/Resources"))
        dirs.append(mainBundle.bundleURL.appendingPathComponent("Resources"))

        // 2. 可执行文件同级及上级
        if let execURL = Bundle.main.executableURL {
            var url = execURL.deletingLastPathComponent()
            dirs.append(url)
            url = url.deletingLastPathComponent()
            dirs.append(url.appendingPathComponent("Resources"))
            url = url.deletingLastPathComponent().deletingLastPathComponent()
            dirs.append(url.appendingPathComponent("DesktopPetForMacApp/Resources"))
            url = url.deletingLastPathComponent()
            dirs.append(url.appendingPathComponent("DesktopPetForMacApp/Resources"))
        }

        // 3. 工作目录
        dirs.append(URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("DesktopPetForMacApp/Resources"))

        return Self.deduplicate(dirs)
    }

    private static func deduplicate(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let key = url.path
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    // MARK: - Public

    func frame(at index: Int) -> NSImage {
        let safeIndex = max(0, min(index, frames.count - 1))
        return frames[safeIndex]
    }

    static func placeholderImage(color: NSColor, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }
}

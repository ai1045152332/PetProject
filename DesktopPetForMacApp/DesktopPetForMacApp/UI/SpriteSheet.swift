// SpriteSheet.swift
// DesktopPetForMacApp — 精灵图帧加载器
// 支持两种资源布局：
//   1. 子文件夹模式（推荐）: Resources/Sprites/{state}/0.png, 1.png, ...
//   2. 扁平模式（SPM 兼容）: Resources/Sprites/{state}_0.png, {state}_1.png, ...

import AppKit
import ImageIO

final class SpriteSheet {
    let state: CatAnimationState
    let frames: [NSImage]
    let frameCount: Int
    var frameDurations: [TimeInterval] = []

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

    init(state: CatAnimationState, image: NSImage) {
        self.state = state
        self.frames = [image]
        self.frameCount = 1
    }

    /// 自动扫描 PNG 帧
    /// 先尝试子文件夹模式，再回退到扁平前缀模式
    init?(state: CatAnimationState) {
        self.state = state

        if let custom = CustomSpriteStore.loadAnimation(for: state) {
            self.frames = custom.frames
            self.frameCount = custom.frames.count
            self.frameDurations = custom.durations
            NSLog("[DesktopPetForMacApp] ✓ Loaded custom image for state '%@'", state.rawValue)
            return
        }

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

enum CustomSpriteStore {
    private static let folderName = "DesktopPetForMacApp/CustomSprites"

    private static var directoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent(folderName, isDirectory: true)
    }

    struct Animation {
        let frames: [NSImage]
        let durations: [TimeInterval]
    }
    static func decodeAnimation(_ data: Data) -> Animation? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 && count <= 120 else { return nil }
        var frames: [NSImage] = []
        var durations: [TimeInterval] = []
        var totalPixels: Int64 = 0
        for index in 0..<count {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                  let w = props[kCGImagePropertyPixelWidth as String] as? Int,
                  let h = props[kCGImagePropertyPixelHeight as String] as? Int,
                  w > 0, h > 0, w <= 8192, h <= 8192 else { return nil }
            totalPixels += Int64(w) * Int64(h)
            guard totalPixels <= 40_000_000,
                  let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            frames.append(NSImage(cgImage: image, size: NSSize(width: w, height: h)))
            let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let duration = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0.1
            durations.append(max(0.02, duration))
        }
        return Animation(frames: frames, durations: durations)
    }
    static func loadAnimation(for state: CatAnimationState, directory: URL? = nil) -> Animation? {
        let root = directory ?? directoryURL
        // A local direct upload always wins over any cloud or legacy image for that state.
        if localSelections(in: root)[state.rawValue] != nil,
           let data = try? Data(contentsOf: root.appendingPathComponent("local-\(state.rawValue).img")),
           let animation = decodeAnimation(data) { return animation }
        let manifest = root.appendingPathComponent("cloud-selections.json")
        let url: URL
        if FileManager.default.fileExists(atPath: manifest.path) {
            guard let data = try? Data(contentsOf: manifest),
                  let selections = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
            if let id = selections[state.rawValue] {
                guard validID(id) else { return nil } // Empty ID explicitly restores the built-in state.
                url = root.appendingPathComponent("cloud-\(id).img")
            } else {
                return loadLegacyAnimation(for: state, directory: root)
            }
        } else {
            return loadLegacyAnimation(for: state, directory: root)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodeAnimation(data)
    }
    private static func loadLegacyAnimation(for state: CatAnimationState, directory: URL) -> Animation? {
        // Keep both the previous shared cloud cache and the app's original per-state uploads readable.
        for name in ["current.png", "\(state.rawValue).png"] {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
               let animation = decodeAnimation(data) { return animation }
        }
        return nil
    }
    private static func validID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { "0123456789abcdef".contains($0) }
    }
    static func hasCustomImage(for state: CatAnimationState) -> Bool { loadAnimation(for: state) != nil }
    static func hasLocalImage(for state: CatAnimationState) -> Bool {
        let root = directoryURL
        return localSelections(in: root)[state.rawValue] != nil
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("local-\(state.rawValue).img").path)
    }
    private static func localSelections(in root: URL) -> [String: String] {
        let manifest = root.appendingPathComponent("local-selections.json")
        guard let data = try? Data(contentsOf: manifest),
              let selections = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return selections
    }

    // Direct uploads stay on this machine: validated pixels are staged first, then the manifest commits.
    static func installLocalImage(_ data: Data, for state: CatAnimationState, directory: URL? = nil) throws {
        guard decodeAnimation(data) != nil else { throw CocoaError(.fileReadCorruptFile) }
        let root = directory ?? directoryURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent("local-\(state.rawValue).img"), options: .atomic)
        var merged = localSelections(in: root)
        merged[state.rawValue] = "1"
        try JSONEncoder().encode(merged).write(to: root.appendingPathComponent("local-selections.json"), options: .atomic)
    }
    static func removeLocalImage(for state: CatAnimationState, directory: URL? = nil) throws {
        let root = directory ?? directoryURL
        var merged = localSelections(in: root)
        merged.removeValue(forKey: state.rawValue)
        try JSONEncoder().encode(merged).write(to: root.appendingPathComponent("local-selections.json"), options: .atomic)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("local-\(state.rawValue).img"))
    }

    // Immutable files are staged first; one atomic manifest commit changes all selected states.
    // Missing states keep their local images; an explicit empty ID means restore default.
    static func installCloudImages(selections: [String: String], images: [String: Data], directory: URL? = nil) throws {
        let root = directory ?? directoryURL
        let manifest = root.appendingPathComponent("cloud-selections.json")
        var merged: [String: String] = [:]
        if FileManager.default.fileExists(atPath: manifest.path) {
            merged = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
        }
        for (state, id) in selections {
            guard CatAnimationState(rawValue: state) != nil,
                  id.isEmpty || validID(id) else { throw CocoaError(.fileReadCorruptFile) }
            if !id.isEmpty {
                guard let data = images[id], decodeAnimation(data) != nil else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (id, data) in images where selections.values.contains(id) {
            try data.write(to: root.appendingPathComponent("cloud-\(id).img"), options: .atomic)
        }
        for (state, id) in selections { merged[state] = id }
        try JSONEncoder().encode(merged).write(to: manifest, options: .atomic)
    }
}

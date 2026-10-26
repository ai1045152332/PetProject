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
            let selections = cloudSelections(in: root)
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
    /// 图片 ID 会拼进本机文件名，必须挡掉路径分隔符与前导点；
    /// 同时兼容两代服务端格式：旧版纯 32 位十六进制，以及当前“可读名-8 位十六进制”（如 my_cat-1a2b3c4d）。
    /// 旧版只认 32 位十六进制，会把新生成的图一律当成损坏文件拒绝安装。
    private static func validID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 96, !id.hasPrefix(".") else { return false }
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return false }
        if id.count == 32 && id.allSatisfy({ "0123456789abcdef".contains($0) }) { return true }
        guard let dash = id.lastIndex(of: "-") else { return false }
        let suffix = id[id.index(after: dash)...]
        return !id[..<dash].isEmpty && suffix.count == 8
            && suffix.allSatisfy { "0123456789abcdef".contains($0) }
    }
    static func hasCustomImage(for state: CatAnimationState) -> Bool { loadAnimation(for: state) != nil }
    static func hasLocalImage(for state: CatAnimationState) -> Bool {
        let root = directoryURL
        return localSelections(in: root)[state.rawValue] != nil
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("local-\(state.rawValue).img").path)
    }
    static func localSelections(in root: URL) -> [String: String] {
        let manifest = root.appendingPathComponent("local-selections.json")
        guard let data = try? Data(contentsOf: manifest),
              let selections = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return selections
    }
    static func cloudSelections(in root: URL) -> [String: String] {
        let manifest = root.appendingPathComponent("cloud-selections.json")
        guard let data = try? Data(contentsOf: manifest),
              let selections = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return selections
    }

    // MARK: - AI 图的状态归属

    /// AI 图 → 生成时所属状态。选中清单（cloud-selections）只记“当前用哪张”，
    /// 换图或删除后归属就丢了；这份清单独立持久化，历史图片才能长期按状态分类。
    private static let cloudStatesFileName = "cloud-states.json"
    static func cloudStates(in root: URL) -> [String: String] {
        let url = root.appendingPathComponent(cloudStatesFileName)
        guard let data = try? Data(contentsOf: url),
              let states = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return states
    }

    /// 只记首次归属：同一张图后来被应用到别的状态时，不改写它的“生成状态”。
    private static func recordCloudStates(_ pairs: [(id: String, state: CatAnimationState)], in root: URL) {
        guard !pairs.isEmpty else { return }
        var states = cloudStates(in: root)
        var changed = false
        for pair in pairs where validID(pair.id) && states[pair.id] == nil {
            states[pair.id] = pair.state.rawValue
            changed = true
        }
        guard changed, let data = try? JSONEncoder().encode(states) else { return }
        try? data.write(to: root.appendingPathComponent(cloudStatesFileName), options: .atomic)
    }

    private static func forgetCloudState(id: String, in root: URL) {
        var states = cloudStates(in: root)
        guard states.removeValue(forKey: id) != nil,
              let data = try? JSONEncoder().encode(states) else { return }
        try? data.write(to: root.appendingPathComponent(cloudStatesFileName), options: .atomic)
    }

    /// 用服务端记录（每张图自带生成状态）补全本机缺失的归属，已有归属不被覆盖；
    /// 只补本机真实存在的图片，避免把纯云端记录写进本机清单。
    /// 返回是否写入了新归属，供界面决定要不要刷新列表。
    @discardableResult
    static func mergeCloudStates(_ records: [String: String], directory: URL? = nil) -> Bool {
        let root = directory ?? directoryURL
        let pairs = records.compactMap { id, raw -> (id: String, state: CatAnimationState)? in
            guard let state = CatAnimationState(rawValue: raw),
                  FileManager.default.fileExists(atPath: root.appendingPathComponent("cloud-\(id).img").path)
            else { return nil }
            return (id: id, state: state)
        }
        let before = cloudStates(in: root)
        recordCloudStates(pairs, in: root)
        return cloudStates(in: root) != before
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
        clearFailure(for: state, directory: root)
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
    // Unknown state keys (e.g. legacy "warn" records left on the server) are skipped, not fatal.
    static func installCloudImages(selections: [String: String], images: [String: Data], directory: URL? = nil) throws {
        let root = directory ?? directoryURL
        let manifest = root.appendingPathComponent("cloud-selections.json")
        var merged: [String: String] = [:]
        if FileManager.default.fileExists(atPath: manifest.path) {
            merged = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
        }
        var known: [String: String] = [:]
        for (state, id) in selections {
            guard CatAnimationState(rawValue: state) != nil else { continue }
            guard id.isEmpty || validID(id) else { throw CocoaError(.fileReadCorruptFile) }
            if !id.isEmpty {
                guard let data = images[id], decodeAnimation(data) != nil else { throw CocoaError(.fileReadCorruptFile) }
            }
            known[state] = id
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (id, data) in images where known.values.contains(id) {
            try data.write(to: root.appendingPathComponent("cloud-\(id).img"), options: .atomic)
        }
        for (state, id) in known { merged[state] = id }
        try JSONEncoder().encode(merged).write(to: manifest, options: .atomic)
        // 只有被单一状态引用的图才算“某状态生成”；被多状态共享的老图（旧版共享图、服务端恢复）
        // 本就无状态归属，写成第一个状态会归类错误。
        var owners: [String: CatAnimationState] = [:]
        var shared = Set<String>()
        for state in CatAnimationState.allCases {
            guard let id = known[state.rawValue], !id.isEmpty else { continue }
            if owners[id] != nil { shared.insert(id) } else { owners[id] = state }
        }
        recordCloudStates(owners.filter { !shared.contains($0.key) }.map { (id: $0.key, state: $0.value) }, in: root)
    }

    /// 预览或应用某张云端图后落盘：重开历史图片即可直接读本地，无需再向服务端取图。
    /// 已存在则跳过，避免重复写；仅作缓存，不改动 cloud-selections 清单。
    static func cacheCloudImage(id: String, data: Data, directory: URL? = nil) {
        guard validID(id) else { return }
        let root = directory ?? directoryURL
        let url = root.appendingPathComponent("cloud-\(id).img")
        if FileManager.default.fileExists(atPath: url.path) { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            FileLogger.log("[PetImages] 缓存云端图片失败: \(error.localizedDescription)")
        }
    }
    /// 读取本地已缓存的云端图；命中则预览/应用都无需走网络。
    static func cachedCloudImage(id: String, directory: URL? = nil) -> Data? {
        guard validID(id) else { return nil }
        let url = (directory ?? directoryURL).appendingPathComponent("cloud-\(id).img")
        return try? Data(contentsOf: url)
    }

    // MARK: - 本机图片历史（数据源完全在本机，服务端只负责生成与存储）

    /// 唯一标识：云端图 `cloud:<图片ID>`，直接上传图 `local:<状态>`。
    static func cloudKey(_ id: String) -> String { "cloud:" + id }
    static func directKey(_ state: CatAnimationState) -> String { "local:" + state.rawValue }
    private static func cloudID(from key: String) -> String? {
        guard key.hasPrefix("cloud:") else { return nil }
        let id = String(key.dropFirst("cloud:".count))
        return validID(id) ? id : nil
    }
    private static func directState(from key: String) -> CatAnimationState? {
        guard key.hasPrefix("local:") else { return nil }
        return CatAnimationState(rawValue: String(key.dropFirst("local:".count)))
    }

    /// 一条本机图片记录：图片文件本身即真相，选中关系另由 selections 清单记录。
    struct LocalImageItem {
        let key: String
        let isDirect: Bool
        let url: URL
        let modified: Date
        let size: Int
        /// 直传图固定绑定状态；AI 图取“生成状态”，老图未记录时按当前选中回填，仍无法判定则为 nil
        let boundState: CatAnimationState?
        let selectedStates: [CatAnimationState]
    }

    /// 枚举本机全部图片：AI 生成下载的 `cloud-<id>.img` + 直接上传的 `local-<state>.img`。
    static func localImages(directory: URL? = nil) -> [LocalImageItem] {
        let root = directory ?? directoryURL
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return [] }
        let cloud = cloudSelections(in: root)
        let local = localSelections(in: root)
        var ownership = cloudStates(in: root)
        var backfilled: [(id: String, state: CatAnimationState)] = []
        var items: [LocalImageItem] = []
        for url in files where url.pathExtension.lowercased() == "img" {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            if name.hasPrefix("cloud-") {
                let id = String(name.dropFirst("cloud-".count).dropLast(".img".count))
                guard validID(id) else { continue }
                let states = CatAnimationState.allCases.filter { cloud[$0.rawValue] == id }
                var owner = ownership[id].flatMap(CatAnimationState.init(rawValue:))
                // 老版本没记生成状态：唯一被一个状态选中才是可靠线索，回填一次后永久归类。
                if owner == nil, states.count == 1, let inferred = states.first {
                    ownership[id] = inferred.rawValue
                    backfilled.append((id: id, state: inferred))
                    owner = inferred
                }
                items.append(LocalImageItem(key: cloudKey(id), isDirect: false, url: url,
                                            modified: modified, size: size, boundState: owner, selectedStates: states))
            } else if name.hasPrefix("local-") {
                let raw = String(name.dropFirst("local-".count).dropLast(".img".count))
                guard let state = CatAnimationState(rawValue: raw) else { continue }
                let active = local[state.rawValue] != nil ? [state] : []
                items.append(LocalImageItem(key: directKey(state), isDirect: true, url: url,
                                            modified: modified, size: size, boundState: state, selectedStates: active))
            }
        }
        recordCloudStates(backfilled, in: root)
        return items.sorted { $0.modified > $1.modified }
    }

    static func imageData(for key: String, directory: URL? = nil) -> Data? {
        let root = directory ?? directoryURL
        if let id = cloudID(from: key) {
            return try? Data(contentsOf: root.appendingPathComponent("cloud-\(id).img"))
        }
        if let state = directState(from: key) {
            return try? Data(contentsOf: root.appendingPathComponent("local-\(state.rawValue).img"))
        }
        return nil
    }

    /// 本机是否已表达过图片选择（清单文件存在即算，包括“全部恢复默认”）：
    /// 用于判断能否用服务端记录做首次恢复，避免覆盖用户本机的选择。
    static func hasAnySelection(directory: URL? = nil) -> Bool {
        let root = directory ?? directoryURL
        let fm = FileManager.default
        return fm.fileExists(atPath: root.appendingPathComponent("cloud-selections.json").path)
            || fm.fileExists(atPath: root.appendingPathComponent("local-selections.json").path)
    }

    /// 用本机图片的周知标识切换某状态的选中图；文件缺失时把该状态回退为内置默认图并报错。
    static func selectLocalImage(key: String, for state: CatAnimationState, directory: URL? = nil) throws {
        let root = directory ?? directoryURL
        var cloud = cloudSelections(in: root)
        var local = localSelections(in: root)
        if let id = cloudID(from: key) {
            let file = root.appendingPathComponent("cloud-\(id).img")
            guard FileManager.default.fileExists(atPath: file.path) else {
                cloud[state.rawValue] = "" // 空标识 = 恢复内置默认图
                try commit(cloud: cloud, local: local, in: root)
                throw CocoaError(.fileNoSuchFile)
            }
            cloud[state.rawValue] = id
            local.removeValue(forKey: state.rawValue)
            recordCloudStates([(id: id, state: state)], in: root)
        } else if let bound = directState(from: key) {
            guard bound == state else {
                throw CocoaError(.fileWriteInvalidFileName, userInfo: [
                    NSLocalizedDescriptionKey: "直接上传的图片只适用于\(bound.displayName)状态"
                ])
            }
            let file = root.appendingPathComponent("local-\(bound.rawValue).img")
            guard FileManager.default.fileExists(atPath: file.path) else {
                local.removeValue(forKey: state.rawValue)
                try commit(cloud: cloud, local: local, in: root)
                throw CocoaError(.fileNoSuchFile)
            }
            local[state.rawValue] = "1"
            cloud[state.rawValue] = ""
        } else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "无法识别的图片标识"])
        }
        try commit(cloud: cloud, local: local, in: root)
    }

    /// 删除一张本机图片；若它正被某些状态选中，这些状态回退为内置默认图。
    static func removeLocalImage(key: String, directory: URL? = nil) throws {
        let root = directory ?? directoryURL
        if let id = cloudID(from: key) {
            var cloud = cloudSelections(in: root)
            for (state, value) in cloud where value == id { cloud[state] = "" }
            try? FileManager.default.removeItem(at: root.appendingPathComponent("cloud-\(id).img"))
            forgetCloudState(id: id, in: root)
            try commit(cloud: cloud, local: localSelections(in: root), in: root)
        } else if let state = directState(from: key) {
            try removeLocalImage(for: state, directory: root)
        }
    }

    /// 恢复内置默认图：清掉该状态的直传图与选中标识（空标识 = 内置默认）。
    static func restoreDefault(for state: CatAnimationState, directory: URL? = nil) throws {
        let root = directory ?? directoryURL
        var cloud = cloudSelections(in: root)
        var local = localSelections(in: root)
        cloud[state.rawValue] = ""
        local.removeValue(forKey: state.rawValue)
        try commit(cloud: cloud, local: local, in: root)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("local-\(state.rawValue).img"))
        clearFailure(for: state, directory: root)
    }

    private static func commit(cloud: [String: String], local: [String: String], in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(cloud).write(to: root.appendingPathComponent("cloud-selections.json"), options: .atomic)
        try JSONEncoder().encode(local).write(to: root.appendingPathComponent("local-selections.json"), options: .atomic)
    }

    /// 落盘一张云端图并设为某状态选中图（同时清掉该状态的本机直传遮挡）。
    static func installCloudImage(id: String, data: Data, for state: CatAnimationState, directory: URL? = nil) throws {
        try installCloudImages(selections: [state.rawValue: id], images: [id: data], directory: directory)
        try? removeLocalImage(for: state, directory: directory)
        clearFailure(for: state, directory: directory)
    }

    // 生成失败记录：本机没有图片文件即视为失败，保留服务端任务 ID 以便重试。
    struct SpriteFailure: Codable {
        let serverID: String?
        let message: String
        let at: Date
    }
    private static let failuresFileName = "sprite-failures.json"
    static func failures(directory: URL? = nil) -> [String: SpriteFailure] {
        let url = (directory ?? directoryURL).appendingPathComponent(failuresFileName)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: SpriteFailure].self, from: data) else { return [:] }
        return decoded
    }
    static func recordFailure(for state: CatAnimationState, serverID: String?, message: String, directory: URL? = nil) {
        let root = directory ?? directoryURL
        var all = failures(directory: root)
        all[state.rawValue] = SpriteFailure(serverID: serverID, message: message, at: Date())
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: root.appendingPathComponent(failuresFileName), options: .atomic)
    }
    static func clearFailure(for state: CatAnimationState, directory: URL? = nil) {
        let root = directory ?? directoryURL
        var all = failures(directory: root)
        guard all.removeValue(forKey: state.rawValue) != nil,
              let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: root.appendingPathComponent(failuresFileName), options: .atomic)
    }
}

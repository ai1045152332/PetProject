// WordBankManager.swift
// DesktopPetForMacApp — 词库管理器：词库从服务端获取，本地缓存，内置资源兜底
//
// 加载策略：
//   1. 启动时先用「服务端同步缓存（Application Support/WordBankCache）」或
//      「App 内置 Resources/WordBank」填充内存，保证离线/首启秒可用；
//   2. 后台异步请求 GET /api/wordbank/list，按文件字节数对比，
//      只下载有变化的词库（GET /api/wordbank/get?name=xxx），校验能解析为 [Word]
//      后落盘并热更新内存缓存。
// 服务端维护词库文件后，客户端无需重新发版即可获得新词库。

import Foundation

/// 词库管理器：独立管理词库的加载、服务端同步和缓存
class WordBankManager {
    static let shared = WordBankManager()

    /// 内存缓存（category.rawValue -> 单词列表），cacheLock 保护跨线程读写
    private var wordBankCache: [String: [Word]] = [:]
    /// 各词库文件当前生效的字节数（fileName -> size），用于同步时判断是否需要下载
    private var fileSizes: [String: Int64] = [:]
    private let cacheLock = NSLock()

    /// 词库文件映射（分类 -> 文件名）
    private let wordBankFiles: [WordCategory: String] = [
        .cet4: "cet4",
        .cet6: "cet6",
        .ielts: "ielts",
        .travel: "travel"
    ]

    private init() {
        loadLocalWordBanks()
        startSync()
    }

    // MARK: - 本地加载（缓存优先，内置兜底）

    /// 服务端同步缓存目录：~/Library/Application Support/DesktopPetForMacApp/WordBankCache
    private var syncCacheDir: URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport
            .appendingPathComponent("DesktopPetForMacApp", isDirectory: true)
            .appendingPathComponent("WordBankCache", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            FileLogger.log("[WordBankManager] 缓存目录创建失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 加载并解析词库文件，返回单词列表与字节数
    private func loadResult(url: URL) -> (words: [Word], size: Int64)? {
        guard let data = try? Data(contentsOf: url),
              let words = try? JSONDecoder().decode([Word].self, from: data) else {
            return nil
        }
        return (words, Int64(data.count))
    }

    /// 定位单个词库：1) 服务端同步缓存 2) App 内置资源 3) 可执行文件周边（调试/裸二进制）
    private func loadWordBank(fileName: String) -> (words: [Word], size: Int64, source: String)? {
        // 1. 服务端同步缓存（上次联网下载的最新版本）
        if let dir = syncCacheDir {
            let url = dir.appendingPathComponent("\(fileName).json")
            if FileManager.default.fileExists(atPath: url.path), let r = loadResult(url: url) {
                return (r.words, r.size, "同步缓存")
            }
        }

        // 2. App 内置资源：Contents/Resources/WordBank
        // 注意：打包成 .app 后 SPM 的 Bundle.module 首访可能极慢/阻塞主线程，这里直接用 Bundle.main 绝对路径。
        if let res = Bundle.main.resourceURL {
            let url = res.appendingPathComponent("WordBank/\(fileName).json")
            if FileManager.default.fileExists(atPath: url.path), let r = loadResult(url: url) {
                return (r.words, r.size, "打包资源")
            }
        }

        // 3. Fallback：可执行文件周边目录（调试/裸二进制场景）
        let execDir = Bundle.main.bundlePath
        let fallbackPaths = [
            "\(execDir)/Contents/Resources/WordBank/\(fileName).json",
            "\(execDir)/WordBank/\(fileName).json",
            "\(execDir)/../Resources/WordBank/\(fileName).json"
        ]
        for path in fallbackPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path), let r = loadResult(url: url) {
                return (r.words, r.size, "fallback")
            }
        }
        return nil
    }

    /// 加载所有词库到内存（本地，快；服务端同步在后台进行）
    private func loadLocalWordBanks() {
        FileLogger.log("[WordBankManager] 开始加载词库（本地）...")
        cacheLock.lock()
        defer { cacheLock.unlock() }
        for (category, fileName) in wordBankFiles {
            if let result = loadWordBank(fileName: fileName) {
                wordBankCache[category.rawValue] = result.words
                fileSizes[fileName] = result.size
                FileLogger.log("[WordBankManager] ✅ 加载词库 \(fileName): \(result.words.count) 个单词（\(result.source)）")
            } else {
                FileLogger.log("[WordBankManager] ❌ 加载词库 \(fileName) 失败")
            }
        }
        let total = wordBankCache.values.reduce(0) { $0 + $1.count }
        FileLogger.log("[WordBankManager] 本地词库加载完成，共 \(total) 个单词")
    }

    // MARK: - 服务端同步

    /// 服务端词库列表条目
    private struct RemoteBank: Decodable {
        let name: String
        let size: Int64
    }
    private struct BankListResponse: Decodable {
        struct Payload: Decodable { let banks: [RemoteBank] }
        let code: Int
        let data: Payload
    }

    /// 后台队列异步同步，不阻塞启动；失败静默保留本地数据
    private func startSync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.syncFromServer()
        }
    }

    private func syncFromServer() {
        guard let list = fetchBankList() else {
            FileLogger.log("[WordBankManager] 词库同步跳过（服务端不可达或无列表），继续使用本地数据")
            return
        }
        var updated = 0
        for bank in list {
            cacheLock.lock()
            let localSize = fileSizes[bank.name]
            cacheLock.unlock()
            // 字节数一致视为未变化，跳过下载
            if let localSize, localSize == bank.size { continue }
            if downloadBank(name: bank.name) != nil { updated += 1 }
        }
        FileLogger.log("[WordBankManager] 词库同步完成：远端 \(list.count) 个，更新 \(updated) 个")
    }

    /// 下载单个词库：校验可解析为非空 [Word] 才落盘并热更新内存，坏数据绝不覆盖好数据
    @discardableResult
    private func downloadBank(name: String) -> [Word]? {
        guard let url = URL(string: "\(ServerConfig.baseURL)/api/wordbank/get?name=\(name)"),
              let data = syncGet(url: url, timeout: 20),
              let words = try? JSONDecoder().decode([Word].self, from: data),
              !words.isEmpty else {
            FileLogger.log("[WordBankManager] ⚠️ 下载/解析词库失败: \(name)")
            return nil
        }
        if let dir = syncCacheDir {
            let file = dir.appendingPathComponent("\(name).json")
            try? data.write(to: file, options: .atomic)
        }
        cacheLock.lock()
        fileSizes[name] = Int64(data.count)
        if let category = wordBankFiles.first(where: { $0.value == name })?.key {
            wordBankCache[category.rawValue] = words
        }
        cacheLock.unlock()
        FileLogger.log("[WordBankManager] ✅ 词库已从服务端更新: \(name)（\(words.count) 个单词）")
        return words
    }

    private func fetchBankList() -> [RemoteBank]? {
        guard let url = URL(string: "\(ServerConfig.baseURL)/api/wordbank/list"),
              let data = syncGet(url: url, timeout: 10),
              let resp = try? JSONDecoder().decode(BankListResponse.self, from: data),
              resp.code == 0 else { return nil }
        return resp.data.banks
    }

    /// 简单同步 GET（后台队列调用，semaphore 等待，与 LeetCodeService 模式一致）
    private func syncGet(url: URL, timeout: TimeInterval) -> Data? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        var result: Data?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil, let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if let error { FileLogger.log("[WordBankManager] 网络错误: \(error.localizedDescription)") }
                return
            }
            result = data
        }.resume()
        semaphore.wait()
        return result
    }

    // MARK: - 获取词库

    /// 获取指定分类的单词列表
    func getWords(for category: WordCategory) -> [Word] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return wordBankCache[category.rawValue] ?? []
    }

    /// 随机获取指定数量的单词
    func getRandomWords(count: Int, category: WordCategory) -> [Word] {
        let words = getWords(for: category)
        guard !words.isEmpty else {
            FileLogger.log("[WordBankManager] 词库为空: \(category.rawValue)")
            return []
        }
        return Array(words.shuffled().prefix(count))
    }

    // MARK: - 词库统计

    /// 获取词库统计信息
    func getStatistics() -> [WordCategory: Int] {
        var stats: [WordCategory: Int] = [:]
        for category in WordCategory.allCases {
            stats[category] = getWords(for: category).count
        }
        return stats
    }

    /// 获取总单词数
    func getTotalWordCount() -> Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return wordBankCache.values.reduce(0) { $0 + $1.count }
    }

    /// 检查词库是否为空
    func isEmpty(for category: WordCategory) -> Bool {
        return getWords(for: category).isEmpty
    }

    // MARK: - 词库信息

    /// 获取词库当前来源文件路径（用于调试；优先同步缓存）
    func getWordBankPath(for category: WordCategory) -> String? {
        guard let fileName = wordBankFiles[category] else { return nil }
        if let dir = syncCacheDir {
            let url = dir.appendingPathComponent("\(fileName).json")
            if FileManager.default.fileExists(atPath: url.path) { return url.path }
        }
        if let res = Bundle.main.resourceURL {
            let url = res.appendingPathComponent("WordBank/\(fileName).json")
            if FileManager.default.fileExists(atPath: url.path) { return url.path }
        }
        return nil
    }

    /// 打印所有词库信息（调试用）
    func printAllWordBankInfo() {
        FileLogger.log("[WordBankManager] === 词库信息 ===")
        for category in WordCategory.allCases {
            let count = getWords(for: category).count
            let path = getWordBankPath(for: category) ?? "未找到"
            FileLogger.log("[WordBankManager] \(category.displayName): \(count) 个单词")
            FileLogger.log("[WordBankManager]   来源: \(path)")
        }
        FileLogger.log("[WordBankManager] 总计: \(getTotalWordCount()) 个单词")
    }
}

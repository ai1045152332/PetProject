// WordBankManager.swift
// DesktopPetForMacApp — 词库管理器：负责词库的加载、缓存、统计

import Foundation

/// 词库管理器：独立管理词库的加载和缓存
class WordBankManager {
    static let shared = WordBankManager()
    
    /// 词库缓存
    private var wordBankCache: [String: [Word]] = [:]
    private var isLoaded = false
    
    /// 词库文件映射（分类 -> 文件名）
    private let wordBankFiles: [WordCategory: String] = [
        .cet4: "cet4",
        .cet6: "cet6",
        .ielts: "ielts",
        .travel: "travel"
    ]
    
    private init() {
        loadAllWordBanks()
    }
    
    // MARK: - 加载词库
    
    /// 加载所有词库
    private func loadAllWordBanks() {
        guard !isLoaded else { return }
        
        FileLogger.log("[WordBankManager] 开始加载词库...")
        
        for (category, fileName) in wordBankFiles {
            if let words = loadWordBank(fileName: fileName) {
                wordBankCache[category.rawValue] = words
                FileLogger.log("[WordBankManager] ✅ 加载词库 \(fileName): \(words.count) 个单词")
            } else {
                FileLogger.log("[WordBankManager] ❌ 加载词库 \(fileName) 失败")
            }
        }
        
        isLoaded = true
        FileLogger.log("[WordBankManager] 词库加载完成，共 \(wordBankCache.values.reduce(0) { $0 + $1.count }) 个单词")
    }
    
    /// 从 JSON 文件加载词库
    /// 注意：打包成 .app 后 SPM 的 Bundle.module 首访可能极慢/阻塞主线程，
    /// 这里直接用 Bundle.main 的绝对路径定位打包到 Contents/Resources/WordBank 下的词库。
    private func loadWordBank(fileName: String) -> [Word]? {
        // 1. 定位词库目录：优先 app 内 Contents/Resources/WordBank，其次 Bundle.main.subdirectory
        let resourcesURL: URL? = {
            if let res = Bundle.main.resourceURL {
                let wb = res.appendingPathComponent("WordBank", isDirectory: true)
                if FileManager.default.fileExists(atPath: wb.path) { return wb }
            }
            return nil
        }()

        // 2. 在词库目录中找目标文件
        if let dirURL = resourcesURL {
            let url = dirURL.appendingPathComponent("\(fileName).json")
            if FileManager.default.fileExists(atPath: url.path) {
                FileLogger.log("[WordBankManager] ✅ 从打包资源加载: \(url.path)")
                return loadAndParse(url: url, fileName: fileName)
            }
        }

        // 3. Fallback：可执行文件同目录向上若干层找 Resources（调试/裸二进制场景）
        let execDir = Bundle.main.bundlePath
        let fallbackPaths = [
            "\(execDir)/Contents/Resources/WordBank/\(fileName).json",
            "\(execDir)/WordBank/\(fileName).json",
            "\(execDir)/../Resources/WordBank/\(fileName).json"
        ]
        for path in fallbackPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                FileLogger.log("[WordBankManager] ✅ 从 fallback 找到: \(path)")
                return loadAndParse(url: url, fileName: fileName)
            }
        }

        FileLogger.log("[WordBankManager] ❌ 找不到词库文件: \(fileName).json")
        FileLogger.log("[WordBankManager]   Bundle.main.resourceURL=\(String(describing: Bundle.main.resourceURL))")
        return nil
    }
    
    /// 加载并解析 JSON 文件
    private func loadAndParse(url: URL, fileName: String) -> [Word]? {
        do {
            let data = try Data(contentsOf: url)
            let words = try JSONDecoder().decode([Word].self, from: data)
            return words
        } catch {
            FileLogger.log("[WordBankManager] ❌ 解析词库文件失败 \(fileName): \(error)")
            return nil
        }
    }
    
    // MARK: - 获取词库
    
    /// 获取指定分类的单词列表
    func getWords(for category: WordCategory) -> [Word] {
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
        return wordBankCache.values.reduce(0) { $0 + $1.count }
    }
    
    /// 检查词库是否为空
    func isEmpty(for category: WordCategory) -> Bool {
        return getWords(for: category).isEmpty
    }
    
    // MARK: - 词库信息
    
    /// 获取词库文件路径（用于调试）
    func getWordBankPath(for category: WordCategory) -> String? {
        guard let fileName = wordBankFiles[category] else { return nil }
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
            FileLogger.log("[WordBankManager]   路径: \(path)")
        }
        FileLogger.log("[WordBankManager] 总计: \(getTotalWordCount()) 个单词")
    }
}

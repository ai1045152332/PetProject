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
    private func loadWordBank(fileName: String) -> [Word]? {
        // 优先使用 Bundle.module（SPM 资源）
        if let url = Bundle.module.url(forResource: fileName, withExtension: "json", subdirectory: "WordBank") {
            FileLogger.log("[WordBankManager] ✅ 找到资源: \(url.path)")
            return loadAndParse(url: url, fileName: fileName)
        }
        
        // Fallback: 尝试 Bundle.main
        if let url = Bundle.main.url(forResource: fileName, withExtension: "json", subdirectory: "WordBank") {
            FileLogger.log("[WordBankManager] ✅ 从 Bundle.main 找到: \(url.path)")
            return loadAndParse(url: url, fileName: fileName)
        }
        
        // Fallback: 尝试从可执行文件目录加载
        let execDir = Bundle.main.bundlePath
        let paths = [
            "\(execDir)/Contents/Resources/WordBank/\(fileName).json",
            "\(execDir)/WordBank/\(fileName).json",
            "\(execDir)/../Resources/WordBank/\(fileName).json"
        ]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                FileLogger.log("[WordBankManager] ✅ 从 fallback 路径找到: \(path)")
                return loadAndParse(url: url, fileName: fileName)
            }
        }
        
        FileLogger.log("[WordBankManager] ❌ 找不到词库文件: \(fileName).json")
        FileLogger.log("[WordBankManager]   Bundle.module 路径: \(Bundle.module.bundlePath)")
        FileLogger.log("[WordBankManager]   Bundle.main 路径: \(Bundle.main.bundlePath)")
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
        return Bundle.module.url(forResource: fileName, withExtension: "json", subdirectory: "WordBank")?.path
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

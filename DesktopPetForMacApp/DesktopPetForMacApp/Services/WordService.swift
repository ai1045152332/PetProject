// WordService.swift
// DesktopPetForMacApp — 背单词功能：分类管理、学习流程编排

import Foundation

/// 单词数据模型（本地词库，紧凑格式：只存单词 + 中文释义）
/// 音标 / 例句 / 发音等详情不落盘，由 DictionaryService 在学习阶段从 API 预取并缓存
struct Word: Codable {
    let word: String
    let meaning: String    // 中文释义（本地，考试选项用）
}

/// 单词分类
enum WordCategory: String, CaseIterable {
    case cet4 = "四级"
    case cet6 = "六级"
    case ielts = "雅思"
    case travel = "旅行"

    var displayName: String {
        switch self {
        case .cet4: return "📚 四级"
        case .cet6: return "📖 六级"
        case .ielts: return "🎓 雅思"
        case .travel: return "✈️ 旅行"
        }
    }

    var description: String {
        switch self {
        case .cet4: return "大学英语四级核心词汇"
        case .cet6: return "大学英语六级高频词汇"
        case .ielts: return "雅思考试高频词汇"
        case .travel: return "出国旅行常用表达"
        }
    }
}

/// 单词服务：管理分类选择 + 编排学习/测试流程（词库由 WordBankManager 管理，释义由 DictionaryService 获取）
class WordService {
    static let shared = WordService()

    /// 当前选择的分类
    static let categoryKey = "settings.wordCategory"

    var currentCategory: WordCategory {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.categoryKey) ?? WordCategory.cet4.rawValue
            return WordCategory(rawValue: raw) ?? .cet4
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.categoryKey)
        }
    }

    /// 获取当前分类的单词列表（委托给 WordBankManager）
    func getWords(for category: WordCategory) -> [Word] {
        return WordBankManager.shared.getWords(for: category)
    }

    /// 随机获取指定数量的单词（委托给 WordBankManager）
    func getRandomWords(count: Int, category: WordCategory) -> [Word] {
        return WordBankManager.shared.getRandomWords(count: count, category: category)
    }

    /// 获取词库统计
    func getStatistics() -> [WordCategory: Int] {
        return WordBankManager.shared.getStatistics()
    }
}

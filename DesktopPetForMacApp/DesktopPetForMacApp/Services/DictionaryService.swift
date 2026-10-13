// DictionaryService.swift
// DesktopPetForMacApp — 词典服务：Free Dictionary API + Datamuse API + 本地缓存

import Foundation

// MARK: - 数据模型

/// 单词详情（来自 Free Dictionary API）
struct WordDetail {
    let word: String
    let phonetic: String?        // 音标，如 /əˈbændən/
    let meanings: [MeaningEntry] // 词性 + 英文释义 + 例句
    let audioURL: String?        // 发音音频 URL

    /// 第一个中文释义（来自本地词库缓存）
    var chineseMeaning: String?

    struct MeaningEntry {
        let partOfSpeech: String   // n. / v. / adj. ...
        let definitions: [Definition]
        let synonyms: [String]

        struct Definition {
            let definition: String
            let example: String?
        }
    }
}

/// 选择题数据
struct QuizData {
    let word: String               // 目标单词
    let phonetic: String?          // 音标
    let correctAnswer: String      // 正确释义
    let distractors: [String]      // 3 个干扰项
    let example: String?           // 例句
    let audioURL: String?          // 发音 URL
    let partOfSpeech: String?      // 词性

    /// 打乱后的选项列表
    let shuffledOptions: [String]
    /// 正确答案在打乱后列表中的索引
    let correctIndex: Int

    /// 初始化时一次性打乱
    init(word: String, phonetic: String?, correctAnswer: String, distractors: [String], example: String?, audioURL: String?, partOfSpeech: String?) {
        self.word = word
        self.phonetic = phonetic
        self.correctAnswer = correctAnswer
        self.distractors = distractors
        self.example = example
        self.audioURL = audioURL
        self.partOfSpeech = partOfSpeech
        let all = ([correctAnswer] + distractors).shuffled()
        self.shuffledOptions = all
        self.correctIndex = all.firstIndex(of: correctAnswer) ?? 0
    }
}

// MARK: - 词典服务

class DictionaryService {
    static let shared = DictionaryService()

    /// 单词详情缓存
    private var detailCache: [String: WordDetail] = [:]
    /// 本地中文释义缓存（从词库 JSON 加载时填充）
    private var localMeaningCache: [String: String] = [:]

    private init() {
        preloadLocalMeanings()
    }

    // MARK: - 预加载本地释义

    /// 从所有词库预加载 word → 中文释义 映射
    private func preloadLocalMeanings() {
        for category in WordCategory.allCases {
            let words = WordBankManager.shared.getWords(for: category)
            for w in words {
                if !w.meaning.isEmpty {
                    localMeaningCache[w.word.lowercased()] = w.meaning
                }
            }
        }
        FileLogger.log("[DictionaryService] 预加载本地释义 \(localMeaningCache.count) 条")
    }

    /// 获取本地中文释义
    func getLocalMeaning(for word: String) -> String? {
        return localMeaningCache[word.lowercased()]
    }

    // MARK: - Free Dictionary API

    /// 获取单词详情（优先缓存 → API → 本地降级）
    func fetchWordDetail(word: String) async -> WordDetail? {
        let key = word.lowercased()
        if let cached = detailCache[key] { return cached }

        let urlString = "https://api.dictionaryapi.dev/api/v2/entries/en/\(key)"
        guard let data = await fetchData(urlString) else {
            FileLogger.log("[DictionaryService] API 请求失败: \(word)")
            return buildFallbackDetail(word: word)
        }

        do {
            guard let array = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let first = array.first as? [String: Any] else {
                return buildFallbackDetail(word: word)
            }

            let phonetic = first["phonetic"] as? String
            let audioURL = extractAudioURL(from: first["phonetics"] as? [[String: Any]])

            var meanings: [WordDetail.MeaningEntry] = []
            if let meaningsArray = first["meanings"] as? [[String: Any]] {
                for m in meaningsArray.prefix(3) {
                    let pos = m["partOfSpeech"] as? String ?? ""
                    let defs = (m["definitions"] as? [[String: Any]]) ?? []
                    let definitions = defs.map {
                        WordDetail.MeaningEntry.Definition(
                            definition: $0["definition"] as? String ?? "",
                            example: $0["example"] as? String
                        )
                    }
                    let synonyms = (m["synonyms"] as? [String]) ?? []
                    meanings.append(.init(partOfSpeech: pos, definitions: definitions, synonyms: synonyms))
                }
            }

            let detail = WordDetail(
                word: key, phonetic: phonetic,
                meanings: meanings, audioURL: audioURL,
                chineseMeaning: localMeaningCache[key]
            )
            detailCache[key] = detail
            return detail
        } catch {
            FileLogger.log("[DictionaryService] 解析失败: \(error)")
            return buildFallbackDetail(word: word)
        }
    }

    /// 从 phonetics 数组中提取第一个有效音频 URL
    private func extractAudioURL(from phonetics: [[String: Any]]?) -> String? {
        guard let phonetics = phonetics else { return nil }
        for p in phonetics {
            if let audio = p["audio"] as? String, audio.hasPrefix("http") {
                return audio
            }
        }
        return nil
    }

    /// API 失败时的本地降级
    private func buildFallbackDetail(word: String) -> WordDetail? {
        let meaning = localMeaningCache[word.lowercased()]
        guard meaning != nil else { return nil }
        return WordDetail(
            word: word.lowercased(), phonetic: nil,
            meanings: [], audioURL: nil,
            chineseMeaning: meaning
        )
    }

    // MARK: - Datamuse API（近义词 / 联想词）

    /// 获取近义词（用于生成干扰项）
    func fetchSynonyms(word: String) async -> [String] {
        let urlString = "https://api.datamuse.com/words?rel_syn=\(word)&max=10"
        guard let data = await fetchData(urlString) else { return [] }

        do {
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return array.compactMap { $0["word"] as? String }
        } catch {
            FileLogger.log("[DictionaryService] Datamuse 解析失败: \(error)")
            return []
        }
    }

    // MARK: - 生成选择题

    /// 为指定单词生成选择题（3 选 1）
    func generateQuiz(word: Word, category: WordCategory) async -> QuizData? {
        // 1. 获取单词详情
        let detail = await fetchWordDetail(word: word.word)
        let correctAnswer: String
        let example: String?
        let audioURL: String?
        let phonetic: String?
        let partOfSpeech: String?

        if let d = detail {
            // 优先使用本地中文释义
            correctAnswer = d.chineseMeaning ?? extractFirstDefinition(d)
            example = extractFirstExample(d)
            audioURL = d.audioURL
            phonetic = d.phonetic
            partOfSpeech = d.meanings.first?.partOfSpeech
        } else {
            // 完全降级：用本地 JSON 数据
            guard !word.meaning.isEmpty else { return nil }
            correctAnswer = word.meaning
            example = word.example
            audioURL = nil
            phonetic = word.phonetic
            partOfSpeech = nil
        }

        // 2. 生成干扰项
        let distractors = await generateDistractors(
            correctWord: word.word,
            correctMeaning: correctAnswer,
            category: category
        )
        guard distractors.count >= 2 else {
            FileLogger.log("[DictionaryService] 干扰项不足: \(word.word)")
            return nil
        }

        return QuizData(
            word: word.word, phonetic: phonetic,
            correctAnswer: correctAnswer,
            distractors: Array(distractors.prefix(3)),
            example: example, audioURL: audioURL,
            partOfSpeech: partOfSpeech
        )
    }

    /// 从详情中提取第一个英文释义
    private func extractFirstDefinition(_ detail: WordDetail) -> String {
        guard let first = detail.meanings.first,
              let def = first.definitions.first else {
            return detail.chineseMeaning ?? ""
        }
        return def.definition
    }

    /// 从详情中提取第一个例句
    private func extractFirstExample(_ detail: WordDetail) -> String? {
        for m in detail.meanings {
            for d in m.definitions {
                if let ex = d.example, !ex.isEmpty { return ex }
            }
        }
        return nil
    }

    /// 生成干扰项：优先 Datamuse 近义词的中文释义，不足则从词库补充
    private func generateDistractors(correctWord: String, correctMeaning: String, category: WordCategory) async -> [String] {
        var distractors: [String] = []
        let allWords = WordBankManager.shared.getWords(for: category)
        let candidates = allWords.filter { $0.word.lowercased() != correctWord.lowercased() }

        // 尝试从同词库的其他单词获取干扰项
        let shuffled = candidates.shuffled()
        for w in shuffled {
            guard distractors.count < 3 else { break }
            let meaning = localMeaningCache[w.word.lowercased()] ?? w.meaning
            if !meaning.isEmpty && !distractors.contains(meaning) && meaning != correctMeaning {
                distractors.append(meaning)
            }
        }

        return distractors
    }

    // MARK: - 网络请求

    private func fetchData(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        } catch {
            FileLogger.log("[DictionaryService] 网络请求失败: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 缓存管理

    func clearCache() {
        detailCache.removeAll()
        FileLogger.log("[DictionaryService] 缓存已清空")
    }

    var cacheCount: Int { detailCache.count }
}

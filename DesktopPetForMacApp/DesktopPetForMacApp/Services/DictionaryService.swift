// DictionaryService.swift
// DesktopPetForMacApp — 词典服务：有道词典（主源）+ Free Dictionary API（例句增强/兜底）+ 内存缓存
//
// 架构：
// - 本地词库 JSON 只存 word + meaning（紧凑格式）
// - 学习阶段：后台并行预取本轮单词的 API 详情，用户看卡片时数据已就绪
// - 考试阶段：generateQuiz 纯同步读缓存 + 本地释义，0 网络等待
// - 数据源：有道 dict.youdao.com 国内可达（音标 + dictvoice 发音）；
//   Free Dictionary API 部分网络不可达，仅用于例句增强和有道失败时的整体兜底
// - 相同单词的并发请求自动合并（in-flight 去重），失败不缓存、可重试

import Foundation

// MARK: - 数据模型

/// 单词详情（有道主源：音标 + 发音；Free Dictionary 兜底：音标 + 英文释义 + 例句）
struct WordDetail {
    let word: String
    let phonetic: String?        // 音标，如 /əˈbændən/
    let meanings: [MeaningEntry] // 词性 + 英文释义 + 例句（仅 Free Dictionary 源提供）
    let audioURL: String?        // 发音音频 URL（有道 dictvoice，必成功）
    /// 英文例句（例句增强接口填充；无则 UI 隐藏）
    var example: String?

    /// 展示用例句：优先取显式 example，其次扫描 Free Dictionary 的 meanings
    var firstExample: String? {
        if let example, !example.isEmpty { return example }
        for m in meanings {
            for d in m.definitions {
                if let ex = d.example, !ex.isEmpty { return ex }
            }
        }
        return nil
    }

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

/// 选择题数据（释义/干扰项来自本地词库；音标/例句/发音来自预取缓存）
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

final class DictionaryService: @unchecked Sendable {
    static let shared = DictionaryService()

    private let youdaoAPI = "https://dict.youdao.com/jsonapi"
    private let youdaoVoice = "https://dict.youdao.com/dictvoice"
    private let freeDictAPI = "https://api.dictionaryapi.dev/api/v2/entries/en/"

    /// 单词详情缓存（学习阶段预取落这里）
    private var detailCache: [String: WordDetail] = [:]
    /// 在途请求（同词并发合并为一次网络请求）
    private var inFlight: [String: Task<WordDetail?, Never>] = [:]
    /// 保护上面两个可变状态（类被多个 Task 并发访问）
    private let lock = NSLock()

    private init() {}

    // MARK: - 缓存/在途请求的同步访问（锁不跨 async 挂起点）

    private enum DetailLookup {
        case hit(WordDetail)
        case inFlight(Task<WordDetail?, Never>)
    }

    /// 查缓存或创建/加入在途请求（同步，内部持锁）
    private func lookupOrStart(_ key: String) -> DetailLookup {
        lock.lock(); defer { lock.unlock() }
        if let cached = detailCache[key] { return .hit(cached) }
        if let running = inFlight[key] { return .inFlight(running) }
        let task = Task(priority: .utility) { [weak self] in
            await self?.requestWordDetail(key: key)
        }
        inFlight[key] = task
        return .inFlight(task)
    }

    /// 清理已完成的在途请求记录
    private func finishInFlight(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        inFlight[key] = nil
    }

    /// 写入详情缓存
    private func storeDetail(_ detail: WordDetail, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        detailCache[key] = detail
    }

    // MARK: - 缓存读取（同步，考试阶段用）

    /// 同步读取缓存中的单词详情（只查缓存，绝不发网络）
    func cachedDetail(for word: String) -> WordDetail? {
        lock.lock(); defer { lock.unlock() }
        return detailCache[word.lowercased()]
    }

    // MARK: - 预取

    /// 并行预取一批单词详情（学习开始时后台调用，结果落缓存，用户无感知）
    func prefetch(words: [String]) {
        guard !words.isEmpty else { return }
        FileLogger.log("[DictionaryService] 预取 \(words.count) 个单词详情: \(words.joined(separator: ", "))")
        for word in words {
            Task(priority: .utility) { [weak self] in
                _ = await self?.fetchWordDetail(word: word)
            }
        }
    }

    // MARK: - 详情获取（缓存 → 在途合并 → 数据源链）

    /// 获取单词详情：优先缓存；相同单词的并发请求合并为一次；API 失败不缓存、下次可重试
    func fetchWordDetail(word: String) async -> WordDetail? {
        let key = word.lowercased()

        switch lookupOrStart(key) {
        case .hit(let cached):
            return cached
        case .inFlight(let task):
            let result = await task.value
            finishInFlight(key)
            return result
        }
    }

    /// 真正的网络请求 + 解析（结果写入缓存）
    /// 链路：有道（音标+发音，国内快）→ Free Dictionary 例句增强 → Free Dictionary 整体兜底
    private func requestWordDetail(key: String) async -> WordDetail? {
        if var detail = await requestYoudaoDetail(key: key) {
            // 例句增强：有道已不开放免费例句，Free Dictionary 部分网络可达；
            // 短超时、静默失败，拿不到不影响音标/发音
            if detail.firstExample == nil {
                detail.example = await fetchFreeDictExample(key: key)
            }
            storeDetail(detail, forKey: key)
            return detail
        }

        // 兜底：有道失败（如接口变更）时尝试 Free Dictionary 整体解析
        if let detail = await requestFreeDictDetail(key: key) {
            storeDetail(detail, forKey: key)
            return detail
        }

        FileLogger.log("[DictionaryService] 所有词典源均失败: \(key)")
        return nil
    }

    // MARK: - 有道词典（主源）

    /// 有道 jsonapi：ec 英汉词典（美/英音标）；发音用 dictvoice 确定性 URL
    private func requestYoudaoDetail(key: String) async -> WordDetail? {
        var comps = URLComponents(string: youdaoAPI)
        comps?.queryItems = [
            URLQueryItem(name: "jsonversion", value: "2"),
            URLQueryItem(name: "client", value: "mobile"),
            URLQueryItem(name: "dicts", value: "{\"count\":1,\"dicts\":[[\"ec\"]]}"),
            URLQueryItem(name: "q", value: key)
        ]
        guard let url = comps?.url,
              let data = await fetchData(url.absoluteString, timeout: 5) else {
            FileLogger.log("[DictionaryService] 有道请求失败: \(key)")
            return nil
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ec = json["ec"] as? [String: Any],
                  let words = ec["word"] as? [[String: Any]],
                  let first = words.first else {
                return nil
            }
            // 美音优先，英音兜底；有道返回纯文本（如 ˈerpɔːrt），展示时补斜杠
            let raw = (first["usphone"] as? String) ?? (first["ukphone"] as? String)
            let phonetic = raw.map { "/\($0)/" }
            // 发音 URL 确定性存在，基本必成功
            let escaped = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let audio = "\(youdaoVoice)?audio=\(escaped)&type=2"

            return WordDetail(word: key, phonetic: phonetic, meanings: [], audioURL: audio, example: nil)
        } catch {
            FileLogger.log("[DictionaryService] 有道解析失败: \(key) \(error)")
            return nil
        }
    }

    // MARK: - Free Dictionary API（例句增强 / 兜底）

    /// 仅提取第一个英文例句（短超时，供有道主源增强用）
    private func fetchFreeDictExample(key: String) async -> String? {
        guard let data = await fetchData(freeDictAPI + key, timeout: 3) else { return nil }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let first = array.first as? [String: Any],
              let meanings = first["meanings"] as? [[String: Any]] else { return nil }
        for m in meanings {
            if let defs = m["definitions"] as? [[String: Any]] {
                for d in defs {
                    if let ex = d["example"] as? String, !ex.isEmpty { return ex }
                }
            }
        }
        return nil
    }

    /// Free Dictionary 整体解析（有道不可用时的兜底）
    private func requestFreeDictDetail(key: String) async -> WordDetail? {
        guard let data = await fetchData(freeDictAPI + key, timeout: 8) else {
            FileLogger.log("[DictionaryService] Free Dictionary 请求失败: \(key)")
            return nil
        }

        do {
            guard let array = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let first = array.first as? [String: Any] else {
                return nil
            }

            let phoneticsArray = first["phonetics"] as? [[String: Any]]
            // 顶层 phonetic 字段缺失时，从 phonetics[].text 兜底提取
            let phonetic = (first["phonetic"] as? String) ?? extractPhoneticText(from: phoneticsArray)
            let audioURL = extractAudioURL(from: phoneticsArray)

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

            return WordDetail(word: key, phonetic: phonetic, meanings: meanings, audioURL: audioURL, example: nil)
        } catch {
            FileLogger.log("[DictionaryService] Free Dictionary 解析失败: \(key) \(error)")
            return nil
        }
    }

    /// 从 phonetics 数组中提取第一个非空音标文本
    private func extractPhoneticText(from phonetics: [[String: Any]]?) -> String? {
        guard let phonetics = phonetics else { return nil }
        for p in phonetics {
            if let text = p["text"] as? String, !text.isEmpty { return text }
        }
        return nil
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

    // MARK: - 发音

    /// 获取发音音频 URL（点击播放时调用；学习阶段已预取则直接命中缓存）
    func fetchAudioURL(word: String) async -> String? {
        await fetchWordDetail(word: word)?.audioURL
    }

    // MARK: - 生成选择题

    /// 为指定单词生成选择题（3 选 1）
    /// 释义/干扰项全部来自本地词库，音标/例句/发音读预取缓存 —— 纯同步、0 网络等待
    func generateQuiz(word: Word, category: WordCategory) -> QuizData? {
        guard !word.meaning.isEmpty else {
            FileLogger.log("[DictionaryService] 本地词库无释义: \(word.word)")
            return nil
        }
        
        let detail = cachedDetail(for: word.word)

        let distractors = generateDistractorsSync(
            correctWord: word.word,
            correctMeaning: word.meaning,
            category: category
        )
        guard distractors.count >= 2 else {
            FileLogger.log("[DictionaryService] 干扰项不足: \(word.word)")
            return nil
        }
        
        return QuizData(
            word: word.word,
            phonetic: detail?.phonetic,
            correctAnswer: word.meaning,
            distractors: Array(distractors.prefix(3)),
            example: detail?.firstExample,
            audioURL: detail?.audioURL,
            partOfSpeech: detail?.meanings.first?.partOfSpeech
        )
    }
    
    /// 生成干扰项（纯本地，同步）
    private func generateDistractorsSync(correctWord: String, correctMeaning: String, category: WordCategory) -> [String] {
        var distractors: [String] = []
        let allWords = WordBankManager.shared.getWords(for: category)
        let candidates = allWords.filter { $0.word.lowercased() != correctWord.lowercased() }

        for w in candidates.shuffled() {
            guard distractors.count < 3 else { break }
            if !w.meaning.isEmpty && !distractors.contains(w.meaning) && w.meaning != correctMeaning {
                distractors.append(w.meaning)
            }
        }

        return distractors
    }

    // MARK: - 网络请求

    private func fetchData(_ urlString: String, timeout: TimeInterval = 8) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
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
        lock.lock(); defer { lock.unlock() }
        detailCache.removeAll()
        FileLogger.log("[DictionaryService] 缓存已清空")
    }

    var cacheCount: Int {
        lock.lock(); defer { lock.unlock() }
        return detailCache.count
    }
}

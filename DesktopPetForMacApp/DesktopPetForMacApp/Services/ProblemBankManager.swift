// ProblemBankManager.swift
// DesktopPetForMacApp — 刷题服务：从 LeetCode 热题 100 中随机抽一题
// 题库内置本地 JSON（Resources/ProblemBank/hot100.json），离线可用

import Foundation

/// LeetCode 题目模型（对应 hot100.json 条目）
struct LeetCodeProblem: Codable {
    let id: Int          // 题目编号
    let title: String    // 中文标题
    let difficulty: String // 简单 / 中等 / 困难
    let slug: String     // LeetCode.cn URL slug

    /// 题目链接
    var url: URL? { URL(string: "https://leetcode.cn/problems/\(slug)/") }
}

enum ProblemBankManager {

    /// 热题 100 题库（懒加载缓存，加载后只读）
    private static let problems: [LeetCodeProblem] = {
        guard let url = locateBankFile() else {
            FileLogger.log("[ProblemBank] ❌ 未找到题库文件 hot100.json")
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let list = try JSONDecoder().decode([LeetCodeProblem].self, from: data)
            FileLogger.log("[ProblemBank] ✅ 加载题库成功: \(list.count) 道题")
            return list
        } catch {
            FileLogger.log("[ProblemBank] ❌ 题库解析失败: \(error.localizedDescription)")
            return []
        }
    }()

    /// 上一次抽到的题目编号（避免连抽重复，锁保护）
    private static let lastIDLock = NSLock()
    private static var lastProblemID: Int?

    /// 题库是否可用
    static var isEmpty: Bool { problems.isEmpty }

    /// 随机抽一题（避开上一题，题库只有一题时忽略该规则）
    static func randomProblem() -> LeetCodeProblem? {
        guard !problems.isEmpty else { return nil }
        var candidates = problems
        lastIDLock.lock()
        let last = lastProblemID
        lastIDLock.unlock()
        if let last, candidates.count > 1 {
            candidates.removeAll { $0.id == last }
        }
        guard let picked = candidates.randomElement() else { return nil }
        lastIDLock.lock()
        lastProblemID = picked.id
        lastIDLock.unlock()
        return picked
    }

    // MARK: - 私有

    /// 定位题库文件：优先 .app 内 Contents/Resources/ProblemBank，
    /// 其次可执行文件周边目录（调试/裸二进制场景），与 WordBankManager 保持一致
    private static func locateBankFile() -> URL? {
        if let res = Bundle.main.resourceURL {
            let dir = res.appendingPathComponent("ProblemBank", isDirectory: true)
            let url = dir.appendingPathComponent("hot100.json")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let execDir = Bundle.main.bundlePath
        let fallbackPaths = [
            "\(execDir)/Contents/Resources/ProblemBank/hot100.json",
            "\(execDir)/ProblemBank/hot100.json",
            "\(execDir)/../Resources/ProblemBank/hot100.json"
        ]
        for path in fallbackPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}


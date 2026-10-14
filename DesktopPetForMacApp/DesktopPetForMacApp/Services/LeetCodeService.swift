// LeetCodeService.swift
// DesktopPetForMacApp — LeetCode 题干拉取服务
// 通过 leetcode.cn 公开 GraphQL 接口获取题目 HTML 题干，
// 题干内图片下载后内联为 base64，并缓存到本地（离线可复用）

import Foundation

enum LeetCodeService {

    /// 题干详情（HTML 已含内联图片，可直接渲染）
    struct ProblemDetail {
        let slug: String
        let contentHTML: String   // 题干 HTML（图片已转 base64 data URI）
    }

    /// GraphQL 查询：题号 / 标题 / 难度 / 中文题干 HTML
    private static let graphqlQuery = """
    query questionDetail($titleSlug: String!) {
      question(titleSlug: $titleSlug) {
        questionFrontendId
        translatedTitle
        difficulty
        translatedContent
        content
      }
    }
    """

    /// 图片内联上限（防止极端题目图片过多拖慢加载）
    private static let maxImageCount = 30
    /// 单张图片大小上限（5MB，超过则跳过该图）
    private static let maxImageBytes = 5 * 1024 * 1024

    // MARK: - 对外

    /// 拉取题干（同步方法，请在后台线程调用）
    /// 优先读本地缓存；未命中则请求 GraphQL 并将图片内联后落盘缓存
    static func fetchDetail(slug: String) -> ProblemDetail? {
        // 1. 本地缓存命中直接返回（图片已内联，离线可用）
        if let cached = loadCache(slug: slug) {
            FileLogger.log("[LeetCode] 题干命中本地缓存: \(slug)")
            return ProblemDetail(slug: slug, contentHTML: cached)
        }

        // 2. 请求 GraphQL
        guard let json = requestGraphQL(slug: slug),
              let data = json["data"] as? [String: Any],
              let question = data["question"] as? [String: Any] else {
            FileLogger.log("[LeetCode] ❌ GraphQL 请求失败或响应异常: \(slug)")
            return nil
        }
        // 中文题干优先，缺失时回退英文题干
        let content = (question["translatedContent"] as? String)
            ?? (question["content"] as? String) ?? ""

        // 3. 图片下载并内联为 base64
        let inlined = inlineImages(in: content)

        // 4. 写入本地缓存
        saveCache(slug: slug, html: inlined)
        FileLogger.log("[LeetCode] ✅ 题干拉取成功: \(slug)，内联图片后 \(inlined.count) 字符")
        return ProblemDetail(slug: slug, contentHTML: inlined)
    }

    // MARK: - 网络

    /// 请求 LeetCode GraphQL（同步）
    private static func requestGraphQL(slug: String) -> [String: Any]? {
        guard let url = URL(string: "https://leetcode.cn/graphql/") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://leetcode.cn", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "query": graphqlQuery,
            "variables": ["titleSlug": slug],
            "operationName": "questionDetail"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var result: [String: Any]?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            guard error == nil, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if let error { FileLogger.log("[LeetCode] 网络错误: \(error.localizedDescription)") }
                return
            }
            result = json
        }.resume()
        semaphore.wait()
        return result
    }

    /// 将 HTML 中所有 <img src="http..."> 下载并替换为 base64 data URI（同步）
    private static func inlineImages(in html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<img[^>]+src="(https?://[^"]+)""#) else {
            return html
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        var result = html
        // 倒序替换，避免范围位移
        let limited = matches.prefix(maxImageCount)
        for match in limited.reversed() {
            let srcRange = match.range(at: 1)
            guard let src = ns.substring(with: srcRange).addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
                  let url = URL(string: src) else { continue }
            if let dataURI = downloadAsDataURI(url: url) {
                let fullRange = match.range
                // 找到原 img 标签整体做 src 替换（保留其余属性）
                let tag = ns.substring(with: fullRange)
                let replaced = tag.replacingOccurrences(of: ns.substring(with: srcRange), with: dataURI)
                result = result.replacingOccurrences(of: tag, with: replaced)
            }
        }
        return result
    }

    /// 下载图片并转为 data URI（同步，失败返回 nil 跳过该图）
    private static func downloadAsDataURI(url: URL) -> String? {
        var result: String?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil, let data, data.count <= maxImageBytes else { return }
            // 根据 Content-Type 或扩展名推断 MIME
            var mime = (response as? HTTPURLResponse)?.mimeType ?? "image/png"
            if !mime.hasPrefix("image/") { mime = "image/png" }
            result = "data:\(mime);base64,\(data.base64EncodedString())"
        }.resume()
        semaphore.wait()
        return result
    }

    // MARK: - 本地缓存

    /// 缓存目录：~/Library/Application Support/DesktopPetForMacApp/ProblemCache
    private static var cacheDir: URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport
            .appendingPathComponent("DesktopPetForMacApp", isDirectory: true)
            .appendingPathComponent("ProblemCache", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            FileLogger.log("[LeetCode] 缓存目录创建失败: \(error.localizedDescription)")
            return nil
        }
    }

    private static func loadCache(slug: String) -> String? {
        guard let dir = cacheDir else { return nil }
        let file = dir.appendingPathComponent("\(slug).html")
        return try? String(contentsOf: file, encoding: .utf8)
    }

    private static func saveCache(slug: String, html: String) {
        guard let dir = cacheDir else { return }
        let file = dir.appendingPathComponent("\(slug).html")
        do {
            try html.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            FileLogger.log("[LeetCode] 题干缓存写入失败: \(error.localizedDescription)")
        }
    }
}


import Foundation

struct NewsItem {
    let rank: Int
    let title: String
    let url: String
}

/// 热点新闻获取器（纯工具类，无 Actor 隔离，可在任意线程调用）
struct NewsFetcher {
    static func fetchHotNews() -> [NewsItem] {
        // 主源：今日头条热榜
        if let items = fetchFromToutiao() {
            return items
        }

        // 备用源：百度热搜
        if let items = fetchFromBaidu() {
            return items
        }

        return []
    }

    private static func fetchFromToutiao() -> [NewsItem]? {
        guard let data = NetworkClient.fetchData("https://www.toutiao.com/hot-event/hot-board/?origin=toutiao_pc", timeout: 8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newsData = json["data"] as? [[String: Any]],
              !newsData.isEmpty else {
            return nil
        }

        var items: [NewsItem] = []
        for (index, item) in newsData.prefix(10).enumerated() {
            let title = item["Title"] as? String ?? "无标题"
            let url = item["Url"] as? String ?? ""
            items.append(NewsItem(rank: index + 1, title: title, url: url))
        }
        return items
    }

    private static func fetchFromBaidu() -> [NewsItem]? {
        guard let data = NetworkClient.fetchData("https://top.baidu.com/api/board?platform=wise&tab=realtime", timeout: 8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let top = json["data"] as? [String: Any],
              let cards = top["cards"] as? [[String: Any]],
              let firstCard = cards.first else {
            return nil
        }

        var rawItems: [[String: Any]] = []
        if let contentList = firstCard["content"] as? [[String: Any]],
           let firstItem = contentList.first,
           let innerContent = firstItem["content"] as? [[String: Any]] {
            rawItems = innerContent
        } else if let contentList = firstCard["content"] as? [[String: Any]] {
            rawItems = contentList
        }

        guard !rawItems.isEmpty else { return nil }

        var items: [NewsItem] = []
        for (index, item) in rawItems.prefix(10).enumerated() {
            let title = item["query"] as? String
                       ?? item["word"] as? String
                       ?? item["title"] as? String
                       ?? "无标题"
            let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
            let url = "https://www.baidu.com/s?wd=\(encoded)"
            items.append(NewsItem(rank: index + 1, title: title, url: url))
        }
        return items
    }
}

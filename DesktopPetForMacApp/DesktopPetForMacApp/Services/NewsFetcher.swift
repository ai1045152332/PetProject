import Foundation

struct NewsItem {
    let rank: Int
    let title: String
    let url: String
}

/// 热点新闻获取器（纯工具类，无 Actor 隔离，可在任意线程调用）
/// 抓取与 TTL 缓存都在服务端（GET /api/news），客户端只取现成榜单：
/// 不再直连头条/百度，也不在本地缓存，多端拿到的就是同一份热搜。
struct NewsFetcher {
    static func fetchHotNews() -> [NewsItem] {
        guard let data = NetworkClient.fetchData(ServerConfig.baseURL + "/api/news", timeout: 8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let rawItems = payload["items"] as? [[String: Any]],
              !rawItems.isEmpty else {
            return []
        }

        var items: [NewsItem] = []
        for (index, item) in rawItems.prefix(10).enumerated() {
            let title = item["title"] as? String ?? ""
            guard !title.isEmpty else { continue }
            let rank = (item["rank"] as? Int) ?? (index + 1)
            items.append(NewsItem(rank: rank, title: title, url: item["url"] as? String ?? ""))
        }
        return items
    }
}

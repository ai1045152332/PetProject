// StockHistoryManager.swift
// DesktopPetForMacApp — 股票查询历史记录（UserDefaults 持久化）

import Foundation

struct StockHistoryItem: Codable {
    let code: String
    let name: String
    let timestamp: Date
}

class StockHistoryManager {
    static let shared = StockHistoryManager()
    private let key = "desktoppetformacapp.stock_history"
    private let maxCount = 10
    private let lock = NSLock()
    
    func load() -> [StockHistoryItem] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([StockHistoryItem].self, from: data) else {
            return []
        }
        return items
    }
    
    func add(code: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        var items = load()
        // 去重：如果已存在，先删除旧的
        items.removeAll { $0.code == code }
        // 插入到最前面
        let item = StockHistoryItem(code: code, name: name, timestamp: Date())
        items.insert(item, at: 0)
        // 限制数量
        if items.count > maxCount {
            items = Array(items.prefix(maxCount))
        }
        save(items)
    }
    
    private func save(_ items: [StockHistoryItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

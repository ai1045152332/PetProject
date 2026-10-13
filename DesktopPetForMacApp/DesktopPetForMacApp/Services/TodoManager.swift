// TodoManager.swift
// DesktopPetForMacApp — 本地待办事项管理（UserDefaults 持久化）

import Foundation

struct TodoItem: Codable {
    let id: String
    let text: String
}

class TodoManager {
    static let shared = TodoManager()
    private let key = "desktoppetformacapp.todos"
    private let lock = NSLock()
    
    func load() -> [TodoItem] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }
    
    func add(text: String) {
        lock.lock()
        defer { lock.unlock() }
        var items = loadUnlocked()
        let item = TodoItem(id: UUID().uuidString, text: text)
        items.append(item)
        save(items)
    }
    
    func delete(id: String) {
        lock.lock()
        defer { lock.unlock() }
        var items = loadUnlocked()
        items.removeAll { $0.id == id }
        save(items)
    }
    
    /// 无锁读取（调用方须已持有 lock，避免 NSLock 不可重入导致死锁）
    private func loadUnlocked() -> [TodoItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([TodoItem].self, from: data) else {
            return []
        }
        return items
    }
    
    private func save(_ items: [TodoItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

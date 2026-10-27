// TodoManager.swift
// DesktopPetForMacApp — 本地待办事项管理（UserDefaults 持久化）

import Foundation

struct TodoItem: Codable {
    let id: String
    let text: String
    /// 到点提醒时间（可选）。为 nil 表示不设时间，仅靠主动搭话提醒。
    /// 与 lastNotifiedAt 均为 Optional，旧版仅含 id/text 的 JSON 可正常解码（缺字段自动为 nil）。
    var dueDate: Date? = nil
    /// 上次因到期而触达提醒的时间（可选）。用于「每过一段时间重复提醒，直到被删除」。
    var lastNotifiedAt: Date? = nil
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
    
    func add(text: String, dueDate: Date? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var items = loadUnlocked()
        let item = TodoItem(id: UUID().uuidString, text: text, dueDate: dueDate)
        items.append(item)
        save(items)
    }

    /// 标记某条待办的到期提醒已触达（记录触达时间，用于按间隔重复提醒）
    func markNotified(id: String, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var items = loadUnlocked()
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].lastNotifiedAt = date
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

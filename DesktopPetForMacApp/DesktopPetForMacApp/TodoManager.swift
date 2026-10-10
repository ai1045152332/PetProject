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
    
    func load() -> [TodoItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([TodoItem].self, from: data) else {
            return []
        }
        return items
    }
    
    func add(text: String) {
        var items = load()
        let item = TodoItem(id: UUID().uuidString, text: text)
        items.append(item)
        save(items)
    }
    
    func delete(id: String) {
        var items = load()
        items.removeAll { $0.id == id }
        save(items)
    }
    
    private func save(_ items: [TodoItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

import SwiftUI

// MARK: - Model

/// Named `TodoItem` rather than `Task` — `Task` is Swift concurrency's type and
/// shadowing it inside an app that uses `DispatchQueue`/async would be a trap.
struct TodoItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    /// Session length for this task, in minutes. Overrides the global focus
    /// duration while the task is active — "focus on this for that much time".
    var minutes: Double
    var done = false
    /// Focus sessions completed against this task.
    var sessions = 0
    /// Minutes actually focused on it, so the number survives duration edits.
    var accumulated: Double = 0
    var created = Date()

    var totalLabel: String {
        accumulated >= 60
            ? String(format: "%.1fh", accumulated / 60)
            : "\(Int(accumulated))m"
    }
}

// MARK: - Store

final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    /// Manual order. Display sorts completed items to the bottom without
    /// disturbing this, so reordering in Settings stays predictable.
    @Published private(set) var items: [TodoItem] = []
    @Published private(set) var activeID: UUID?

    private let d: UserDefaults
    private let itemsKey  = "todoItems"
    private let activeKey = "activeTaskID"

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        if let data = defaults.data(forKey: itemsKey),
           let decoded = try? JSONDecoder().decode([TodoItem].self, from: data) {
            items = decoded
        }
        if let s = defaults.string(forKey: activeKey), let id = UUID(uuidString: s) {
            // Only honour it if the task still exists.
            activeID = items.contains { $0.id == id } ? id : nil
        }
    }

    // MARK: Derived

    var active: TodoItem? {
        guard let activeID else { return nil }
        return items.first { $0.id == activeID }
    }

    /// Pending first, completed last, each keeping its manual order.
    var ordered: [TodoItem] {
        items.filter { !$0.done } + items.filter { $0.done }
    }

    var pendingCount: Int { items.filter { !$0.done }.count }
    var hasCompleted: Bool { items.contains { $0.done } }

    /// Highest-effort tasks first, for the stats panel.
    func topByTime(_ n: Int) -> [TodoItem] {
        items.filter { $0.accumulated > 0 }
            .sorted { $0.accumulated > $1.accumulated }
            .prefix(n)
            .map { $0 }
    }

    // MARK: Mutation

    @discardableResult
    func add(title: String, minutes: Double) -> TodoItem? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let item = TodoItem(title: clean, minutes: Self.sane(minutes))
        items.insert(item, at: 0)      // newest first: you just typed it
        save()
        return item
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        // A deleted task must not stay active, or the engine keeps sizing
        // focus phases from something that no longer exists.
        if activeID == id { activeID = nil }
        save()
    }

    func toggleDone(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done.toggle()
        if items[i].done && activeID == id { activeID = nil }
        save()
    }

    func setTitle(_ id: UUID, _ title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        items[i].title = clean
        save()
    }

    func setMinutes(_ id: UUID, _ minutes: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].minutes = Self.sane(minutes)
        save()
    }

    /// A nominal floor. The UI only ever offers 5 minutes and up; this exists
    /// to reject zero, negative and absurd values from a hand-edited plist, not
    /// to enforce policy — the engine applies its own one-second floor.
    private static func sane(_ m: Double) -> Double {
        guard m.isFinite else { return 25 }
        return min(max(m, 0.01), 180)
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func clearCompleted() {
        items.removeAll { $0.done }
        if let a = activeID, !items.contains(where: { $0.id == a }) { activeID = nil }
        save()
    }

    func activate(_ id: UUID?) {
        activeID = id
        save()
    }

    /// Called by the engine when a focus session finishes.
    func creditActive(minutes: Double) {
        guard let activeID, let i = items.firstIndex(where: { $0.id == activeID })
        else { return }
        items[i].sessions += 1
        items[i].accumulated += minutes
        save()
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            d.set(data, forKey: itemsKey)
        }
        d.set(activeID?.uuidString, forKey: activeKey)
    }
}

// MARK: - Duration choices

enum TaskDuration {
    /// Offered in the compact menus. Deliberately short — a long list in a
    /// 300pt drawer is worse than a slider you can reach in Settings.
    static let choices: [Double] = [5, 10, 15, 20, 25, 30, 40, 45, 50, 60, 90]

    static func label(_ m: Double) -> String {
        m >= 60 && m.truncatingRemainder(dividingBy: 60) == 0
            ? "\(Int(m / 60))h"
            : "\(Int(m))m"
    }
}

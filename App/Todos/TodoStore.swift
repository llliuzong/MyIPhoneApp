import Combine
import Foundation

enum TodoPriority: String, CaseIterable, Codable, Identifiable {
    case p0 = "P0"
    case p1 = "P1"
    case p2 = "P2"

    var id: Self { self }

    var label: String {
        switch self {
        case .p0: "高"
        case .p1: "普通"
        case .p2: "低"
        }
    }
}

struct TodoItem: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    var title: String
    var notes: String
    var priority: TodoPriority
    var completedAt: Date?

    var isCompleted: Bool { completedAt != nil }
}

@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var items: [TodoItem] = []
    private(set) var isAvailable = true

    private let fileURL = URL.applicationSupportDirectory
        .appendingPathComponent("Todos", isDirectory: true)
        .appendingPathComponent("items.json")
    private let logger: AppLogger

    init(logger: AppLogger) {
        self.logger = logger
        do {
            items = try JSONDecoder().decode([TodoItem].self, from: Data(contentsOf: fileURL))
        } catch CocoaError.fileReadNoSuchFile {
            // The first save creates the file.
        } catch {
            isAvailable = false
            logger.record("待办数据读取失败", level: .error)
        }
    }

    var pending: [TodoItem] {
        items.filter { !$0.isCompleted }.sorted {
            if $0.priority != $1.priority { return $0.priority.rawValue < $1.priority.rawValue }
            return $0.createdAt > $1.createdAt
        }
    }

    var completed: [TodoItem] {
        items.filter(\.isCompleted).sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
    }

    func save(id: TodoItem.ID?, title: String, notes: String, priority: TodoPriority) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw StoreError.emptyTitle }
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = items
        if let id {
            guard let index = updated.firstIndex(where: { $0.id == id }) else { throw StoreError.missingItem }
            updated[index].title = title
            updated[index].notes = notes
            updated[index].priority = priority
        } else {
            updated.append(TodoItem(id: UUID(), createdAt: .now, title: title, notes: notes, priority: priority))
        }
        try persist(updated)
        logger.record(id == nil ? "已新增待办" : "已编辑待办")
    }

    func toggleCompletion(id: TodoItem.ID) throws {
        var updated = items
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw StoreError.missingItem }
        let isCompleted = !updated[index].isCompleted
        updated[index].completedAt = isCompleted ? .now : nil
        try persist(updated)
        logger.record(isCompleted ? "待办已完成" : "待办已恢复")
    }

    func delete(id: TodoItem.ID) throws {
        guard items.contains(where: { $0.id == id }) else { throw StoreError.missingItem }
        try persist(items.filter { $0.id != id })
        logger.record("已删除待办")
    }

    private func persist(_ updated: [TodoItem]) throws {
        guard isAvailable else { throw StoreError.unavailable }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(updated)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            items = updated
        } catch {
            logger.record("待办数据写入失败", level: .error)
            throw StoreError.writeFailed
        }
    }

    private enum StoreError: LocalizedError {
        case emptyTitle
        case missingItem
        case unavailable
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .emptyTitle: "请输入标题。"
            case .missingItem: "找不到这条待办。"
            case .unavailable: "待办数据暂不可用，请重开 App 后再试。"
            case .writeFailed: "修改未保存，请检查手机剩余空间后重试。"
            }
        }
    }
}

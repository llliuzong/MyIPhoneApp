import Foundation
import Combine

@MainActor
final class AppLogger: ObservableObject {
    enum Level: String {
        case info = "INFO"
        case error = "ERROR"
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String
    }

    @Published private(set) var entries: [Entry] = []
    private let capacity = 100

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"

    init() {
        record("应用启动")
        if version == "未知" || build == "未知" {
            record("无法读取应用版本或构建编号", level: .error)
        }
    }

    func record(_ message: String, level: Level = .info) {
        entries.append(Entry(date: .now, level: level, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    var exportText: String {
        let formatter = ISO8601DateFormatter()
        let lines = entries.map { entry in
            "\(formatter.string(from: entry.date)) [\(entry.level.rawValue)] \(entry.message)"
        }
        return (["MyIPhoneApp \(version) (Build \(build))"] + lines).joined(separator: "\n")
    }
}

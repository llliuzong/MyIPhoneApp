import Combine
import Foundation
import OSLog

@MainActor
final class AppLogger: ObservableObject {
    enum Level: String {
        case info = "INFO"
        case error = "ERROR"
    }

    private let capacity = 200
    private let formatter = ISO8601DateFormatter()
    private let fallback = Logger(subsystem: "com.example.myiphoneapp", category: "file-log")
    private var lines: [String] = []

    private let fileURL = URL.documentsDirectory.appendingPathComponent("commute.log")
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    init() {
        record("应用冷启动，开始新日志")
    }

    func record(_ message: String, level: Level = .info) {
        lines.append("\(formatter.string(from: .now)) [\(level.rawValue)] \(message)")
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        let header = "LongWay \(version) (Build \(build))"
        let snapshot = ([header] + lines).joined(separator: "\n") + "\n"
        do {
            // Never read or append to a previous process's log.
            try Data(snapshot.utf8).write(to: fileURL, options: .atomic)
        } catch {
            let failure = error as NSError
            fallback.error("Failed to write commute.log: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
        }
    }
}

import Combine
import Foundation

struct PullUpWorkout: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    var repsPerSet: [Int] = []
    var endedAt: Date?
    var durationSeconds: Int?

    var totalReps: Int { repsPerSet.reduce(0, +) }
    var totalSets: Int { repsPerSet.count }

    func elapsed(at date: Date) -> Int {
        max(0, Int(date.timeIntervalSince(startedAt)))
    }

    mutating func addSet(_ reps: Int) throws {
        guard reps > 0, reps <= Int.max - totalReps else { throw PullUpError.invalidReps }
        repsPerSet.append(reps)
    }
}

@MainActor
final class PullUpStore: ObservableObject {
    private struct DataFile: Codable {
        var active: PullUpWorkout?
        var history: [PullUpWorkout] = []
    }

    @Published private var dataFile = DataFile()
    private(set) var isAvailable = true
    private let fileURL = URL.applicationSupportDirectory
        .appendingPathComponent("Workouts", isDirectory: true)
        .appendingPathComponent("pull-ups.json")
    private let logger: AppLogger

    var active: PullUpWorkout? { dataFile.active }
    var history: [PullUpWorkout] { dataFile.history }

    init(logger: AppLogger) {
        self.logger = logger
        do {
            dataFile = try JSONDecoder().decode(DataFile.self, from: Data(contentsOf: fileURL))
        } catch CocoaError.fileReadNoSuchFile {
            // The first workout creates the file.
        } catch {
            isAvailable = false
            logger.record("引体向上记录读取失败", level: .error)
        }
    }

    func start() throws {
        guard active == nil else { return }
        var updated = dataFile
        updated.active = PullUpWorkout(id: UUID(), startedAt: .now)
        try save(updated)
        logger.record("引体向上训练开始")
    }

    func recordSet(_ reps: Int) throws {
        guard var workout = active else { throw PullUpError.noActiveWorkout }
        try workout.addSet(reps)
        var updated = dataFile
        updated.active = workout
        try save(updated)
        logger.record("已记录一组引体向上")
    }

    func finish(lastSet: Int?) throws {
        guard var workout = active else { throw PullUpError.noActiveWorkout }
        if let lastSet { try workout.addSet(lastSet) }
        guard workout.totalSets > 0 else { throw PullUpError.emptyWorkout }

        let end = Date()
        workout.endedAt = end
        workout.durationSeconds = workout.elapsed(at: end)
        var updated = dataFile
        updated.active = nil
        updated.history.insert(workout, at: 0)
        try save(updated)
        logger.record("引体向上训练结束，已保存记录")
    }

    func cancelEmptyWorkout() throws {
        guard let active, active.totalSets == 0 else { return }
        var updated = dataFile
        updated.active = nil
        try save(updated)
        logger.record("已取消空的引体向上训练")
    }

    private func save(_ updated: DataFile) throws {
        guard isAvailable else { throw PullUpError.unavailable }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoded = try JSONEncoder().encode(updated)
            try encoded.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            dataFile = updated
        } catch {
            logger.record("引体向上记录写入失败", level: .error)
            throw PullUpError.writeFailed
        }
    }
}

private enum PullUpError: LocalizedError {
    case invalidReps, noActiveWorkout, emptyWorkout, unavailable, writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidReps: "请输入有效的正整数次数。"
        case .noActiveWorkout: "请先开始训练。"
        case .emptyWorkout: "请先记录一组。"
        case .unavailable: "暂时无法读取训练记录，请重开 App 后再试。"
        case .writeFailed: "训练记录未保存，请稍后重试。"
        }
    }
}

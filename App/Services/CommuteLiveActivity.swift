import ActivityKit
import Foundation
import UIKit

@MainActor
final class CommuteLiveActivity {
    private let logger: AppLogger
    private var activityID: String?
    private var pendingUpdate: Task<Void, Never>?

    init(logger: AppLogger) {
        self.logger = logger
        if #available(iOS 16.1, *) {
            let interrupted = Activity<CommuteActivityAttributes>.activities
            pendingUpdate = Task {
                for activity in interrupted {
                    await Self.end(activity, with: nil, dismissal: .immediate)
                }
                if !interrupted.isEmpty { logger.record("已清理上次通勤的实时活动") }
            }
        }
    }

    func start(direction: String) {
        guard #available(iOS 16.1, *), let direction = CommuteActivityAttributes.Direction(rawValue: direction) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.record("系统实时活动已关闭，本次继续记录通勤")
            return
        }
        do {
            let attributes = CommuteActivityAttributes(direction: direction)
            let activity: Activity<CommuteActivityAttributes>
            if #available(iOS 16.2, *) {
                activity = try Activity.request(attributes: attributes,
                    content: ActivityContent(state: .waiting, staleDate: nil), pushType: nil)
            } else {
                activity = try Activity.request(attributes: attributes, contentState: .waiting, pushType: nil)
            }
            activityID = activity.id
            logger.record("通勤实时活动已开始，等待出发")
        } catch {
            logger.record("通勤实时活动启动失败（错误码 \((error as NSError).code)）", level: .error)
        }
    }

    func depart(at date: Date) {
        guard #available(iOS 16.1, *), let activity = currentActivity() else { return }
        let previous = pendingUpdate
        pendingUpdate = Task {
            await previous?.value
            if #available(iOS 16.2, *) {
                await activity.update(ActivityContent(state: .traveling(startedAt: date), staleDate: nil))
            } else {
                await activity.update(using: .traveling(startedAt: date))
            }
            logger.record("通勤实时活动已更新：出发")
        }
    }

    func finish(arrivalSeconds: Int? = nil) {
        guard #available(iOS 16.1, *), let activity = currentActivity() else {
            activityID = nil
            return
        }
        activityID = nil
        let previous = pendingUpdate
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        func releaseBackgroundTask() {
            guard backgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        if UIApplication.shared.applicationState == .background {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "结束通勤实时活动") {
                releaseBackgroundTask()
            }
        }
        pendingUpdate = Task {
            defer { releaseBackgroundTask() }
            await previous?.value
            if let arrivalSeconds {
                await Self.end(activity, with: .arrived(seconds: arrivalSeconds),
                    dismissal: .after(.now.addingTimeInterval(60)))
                logger.record("通勤实时活动已结束：到达")
            } else {
                await Self.end(activity, with: nil, dismissal: .immediate)
                logger.record("通勤实时活动已结束：通勤中断")
            }
        }
    }

    @available(iOS 16.1, *)
    private func currentActivity() -> Activity<CommuteActivityAttributes>? {
        Activity<CommuteActivityAttributes>.activities.first { $0.id == activityID }
    }

    @available(iOS 16.1, *)
    private static func end(_ activity: Activity<CommuteActivityAttributes>,
                            with state: CommuteActivityAttributes.ContentState?, dismissal: ActivityUIDismissalPolicy) async {
        if #available(iOS 16.2, *) {
            await activity.end(state.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: dismissal)
        } else {
            await activity.end(using: state, dismissalPolicy: dismissal)
        }
    }
}

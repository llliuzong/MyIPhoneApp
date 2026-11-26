import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct CommuteActivityAttributes: ActivityAttributes {
    enum Direction: String, Codable, Hashable {
        case work, home

        var title: String { self == .work ? "上班" : "回家" }
    }

    enum ContentState: Codable, Hashable {
        case waiting
        case traveling(startedAt: Date)
        case arrived(seconds: Int)

        var status: String {
            switch self {
            case .waiting: "等待出发"
            case .traveling: "通勤途中"
            case .arrived: "已到达"
            }
        }
    }

    let direction: Direction
}

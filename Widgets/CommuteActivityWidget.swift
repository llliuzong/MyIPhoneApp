import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CommuteActivityWidget: Widget {
    private let commuteURL = URL(string: "longway://commute")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CommuteActivityAttributes.self) { context in
            HStack(spacing: 12) {
                brandIcon(size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.direction.title)
                        .font(.headline)
                    Text(context.state.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                time(context.state, compact: false)
            }
            .padding(16)
            .widgetURL(commuteURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        brandIcon(size: 24)
                        Text(context.attributes.direction.title)
                            .font(.headline)
                    }
                    .padding(.leading, 3)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.status)
                            .foregroundStyle(.secondary)
                        Spacer()
                        time(context.state, compact: false)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                brandIcon(size: 20)
            } compactTrailing: {
                time(context.state, compact: true)
            } minimal: {
                brandIcon(size: 20)
            }
            .widgetURL(commuteURL)
        }
    }

    private func brandIcon(size: CGFloat) -> some View {
        Image("LongWayActivityIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23))
            .accessibilityLabel("LongWay")
    }

    private func time(_ state: CommuteActivityAttributes.ContentState, compact: Bool) -> some View {
        Group {
            switch state {
            case .waiting:
                if compact { Text("待出发") }
            case .traveling(let startedAt):
                Text(startedAt, style: .timer)
                    .multilineTextAlignment(.trailing)
                    .frame(width: compact ? 53 : 76, alignment: .trailing)
            case .arrived(let seconds):
                Text(Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond)))
            }
        }
        .font(compact ? .caption2.weight(.semibold) : .subheadline.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

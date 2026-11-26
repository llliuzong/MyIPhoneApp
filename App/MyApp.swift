import SwiftUI

@main
struct MyApp: App {
    @StateObject private var logger = AppLogger()

    var body: some Scene {
        WindowGroup {
            AppTabs(logger: logger)
        }
    }
}

@MainActor
private struct AppTabs: View {
    let logger: AppLogger
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var tracker: CommuteTracker
    @StateObject private var todos: TodoStore
    @StateObject private var workouts: PullUpStore
    @StateObject private var audio: CommuteAudioPlayer

    init(logger: AppLogger) {
        self.logger = logger
        _tracker = StateObject(wrappedValue: CommuteTracker(logger: logger))
        _todos = StateObject(wrappedValue: TodoStore(logger: logger))
        _workouts = StateObject(wrappedValue: PullUpStore(logger: logger))
        _audio = StateObject(wrappedValue: CommuteAudioPlayer(logger: logger))
    }

    var body: some View {
        TabView {
            ContentView(logger: logger, tracker: tracker, audio: audio)
                .tabItem { Label("通勤", systemImage: "car") }
            TodoView(store: todos)
                .tabItem { Label("待办", systemImage: "checklist") }
            WorkoutView(store: workouts)
                .tabItem { Label("运动", systemImage: "figure.strengthtraining.traditional") }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                logger.record("应用进入前台")
                tracker.foregrounded()
                Task { await audio.refreshEnabled() }
            case .background:
                audio.saveProgress()
                logger.record("应用进入后台")
            case .inactive: break
            @unknown default: break
            }
        }
        .task { await audio.refreshEnabled() }
    }
}

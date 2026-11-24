import SwiftUI

@main
struct MyApp: App {
    @StateObject private var logger = AppLogger()

    var body: some Scene {
        WindowGroup {
            ContentView(logger: logger)
        }
    }
}

import SwiftUI
import SwiftData

@main
struct SkippingRope_Watch_AppApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: WatchWorkoutRecord.self)
    }
}

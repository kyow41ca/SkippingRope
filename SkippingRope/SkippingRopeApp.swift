import SwiftUI
import SwiftData

@main
struct SkippingRopeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: WorkoutRecord.self)
    }
}

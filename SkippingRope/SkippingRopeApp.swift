import SwiftUI
import SwiftData

@main
struct SkippingRopeApp: App {
    let container: ModelContainer

    init() {
        container = try! ModelContainer(for: WorkoutRecord.self)
        ConnectivityManager.shared.modelContext = container.mainContext
        ConnectivityManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}

import SwiftUI

struct ContentView: View {
    @State private var manager = WatchWorkoutManager()

    var body: some View {
        TabView {
            WatchRecordView(manager: manager)
            if !manager.isRunning && !manager.isPaused {
                WatchHistoryView()
            }
        }
        .tabViewStyle(.verticalPage)
    }
}

#Preview {
    ContentView()
}

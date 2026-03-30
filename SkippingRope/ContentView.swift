import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("記録", systemImage: "play.circle.fill") {
                RecordView()
            }
            Tab("履歴", systemImage: "list.bullet") {
                HistoryView()
            }
            Tab("グラフ", systemImage: "chart.bar.fill") {
                GraphView()
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: WorkoutRecord.self, inMemory: true)
}

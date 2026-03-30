import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    WatchRecordView()
                } label: {
                    Label("ジャンプ記録", systemImage: "figure.jumprope")
                }
            }
            .navigationTitle("なわとび")
        }
    }
}

#Preview {
    ContentView()
}

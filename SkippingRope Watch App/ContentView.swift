import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            WatchRecordView()
            WatchHistoryView()
        }
        .tabViewStyle(.verticalPage)
    }
}

#Preview {
    ContentView()
}

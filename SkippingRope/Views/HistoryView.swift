import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutRecord.date, order: .reverse) private var records: [WorkoutRecord]

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView(
                        "記録がありません",
                        systemImage: "figure.jumprope",
                        description: Text("記録タブでなわとびを記録してみましょう")
                    )
                } else {
                    List {
                        ForEach(records) { record in
                            WorkoutRow(record: record)
                        }
                        .onDelete(perform: deleteRecords)
                    }
                }
            }
            .navigationTitle("履歴")
            .toolbar {
                if !records.isEmpty {
                    EditButton()
                }
            }
        }
    }

    private func deleteRecords(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(records[index])
        }
    }
}

struct WorkoutRow: View {
    let record: WorkoutRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.bold())
                Spacer()
                Text(String(format: "%.0f/分", record.jumpsPerMinute))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Label("\(record.jumpCount)回", systemImage: "figure.jumprope")
                Label(timeString(record.duration), systemImage: "clock")
                Label(String(format: "%.0f kcal", record.calories), systemImage: "flame.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func timeString(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: WorkoutRecord.self, inMemory: true)
}

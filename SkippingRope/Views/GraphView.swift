import SwiftUI
import SwiftData
import Charts

struct GraphView: View {
    @Query(sort: \WorkoutRecord.date, order: .reverse) private var records: [WorkoutRecord]
    @State private var selectedMetric: Metric = .jumpCount

    enum Metric: String, CaseIterable {
        case jumpCount = "回数"
        case duration = "時間(分)"
        case calories = "カロリー"
    }

    private var recentRecords: [WorkoutRecord] {
        Array(records.prefix(14)).reversed()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Picker("メトリック", selection: $selectedMetric) {
                        ForEach(Metric.allCases, id: \.self) { metric in
                            Text(metric.rawValue).tag(metric)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    if records.isEmpty {
                        ContentUnavailableView(
                            "データがありません",
                            systemImage: "chart.bar.fill",
                            description: Text("記録を追加するとグラフが表示されます")
                        )
                        .padding(.top, 60)
                    } else {
                        chartSection
                        summarySection
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("グラフ")
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("直近14セッション")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Chart(recentRecords) { record in
                BarMark(
                    x: .value("日付", record.date, unit: .day),
                    y: .value(selectedMetric.rawValue, metricValue(record))
                )
                .foregroundStyle(.blue.gradient)
                .cornerRadius(4)
            }
            .frame(height: 220)
            .padding(.horizontal)
            .animation(.easeInOut, value: selectedMetric)
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("累計")
                .font(.headline)
                .padding(.horizontal)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                SummaryCard(
                    title: "総ジャンプ数",
                    value: "\(records.reduce(0) { $0 + $1.jumpCount })",
                    unit: "回",
                    icon: "figure.jumprope",
                    color: .blue
                )
                SummaryCard(
                    title: "消費カロリー",
                    value: String(format: "%.0f", records.reduce(0) { $0 + $1.calories }),
                    unit: "kcal",
                    icon: "flame.fill",
                    color: .orange
                )
                SummaryCard(
                    title: "総運動時間",
                    value: String(format: "%.0f", records.reduce(0) { $0 + $1.duration } / 60),
                    unit: "分",
                    icon: "clock.fill",
                    color: .green
                )
                SummaryCard(
                    title: "セッション数",
                    value: "\(records.count)",
                    unit: "回",
                    icon: "list.bullet.clipboard",
                    color: .purple
                )
            }
            .padding(.horizontal)
        }
    }

    private func metricValue(_ record: WorkoutRecord) -> Double {
        switch selectedMetric {
        case .jumpCount: Double(record.jumpCount)
        case .duration: record.duration / 60
        case .calories: record.calories
        }
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(color)

            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title2.bold())
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    GraphView()
        .modelContainer(for: WorkoutRecord.self, inMemory: true)
}

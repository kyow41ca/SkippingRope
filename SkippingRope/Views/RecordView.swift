import SwiftUI
import SwiftData

struct RecordView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var healthKit = HealthKitService()
    @State private var jumpDetector = JumpDetector()

    @State private var isRecording = false
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    @State private var showSaveAlert = false

    private var jumpCount: Int { jumpDetector.jumpCount }

    private var calories: Double {
        WorkoutRecord.calculateCalories(duration: elapsedTime)
    }

    private var pace: Double {
        guard elapsedTime > 0 else { return 0 }
        return Double(jumpCount) / (elapsedTime / 60)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Text(timeString(elapsedTime))
                    .font(.system(size: 72, weight: .thin, design: .monospaced))
                    .foregroundStyle(isRecording ? .primary : .secondary)
                    .contentTransition(.numericText())

                HStack(spacing: 32) {
                    StatCard(title: "ジャンプ", value: "\(jumpCount)", unit: "回")
                    StatCard(title: "カロリー", value: String(format: "%.1f", calories), unit: "kcal")
                    StatCard(title: "ペース", value: String(format: "%.0f", pace), unit: "/分")
                }

                // センサー検出インジケーター + 手動補正ボタン
                VStack(spacing: 8) {
                    if isRecording {
                        Label("加速度センサーで自動検出中", systemImage: "sensor.tag.radiowaves.forward.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }

                    HStack(spacing: 16) {
                        // 手動 -1（誤検知補正）
                        Button {
                            if jumpDetector.jumpCount > 0 { jumpDetector.jumpCount -= 1 }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.title2)
                        }
                        .disabled(!isRecording)
                        .tint(.red)

                        Image(systemName: "figure.jumprope")
                            .font(.system(size: 64))
                            .foregroundStyle(isRecording ? .blue : .gray)
                            .symbolEffect(.variableColor.iterative, isActive: isRecording)

                        // 手動 +1（拾い損ね補正）
                        Button {
                            if isRecording { jumpDetector.jumpCount += 1 }
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.title2)
                        }
                        .disabled(!isRecording)
                        .tint(.blue)
                    }
                }

                Spacer()

                VStack(spacing: 12) {
                    Button(action: toggleRecording) {
                        Text(isRecording ? "停止" : "開始")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(isRecording ? Color.red : Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }

                    if !isRecording && elapsedTime > 0 {
                        Button("リセット", role: .destructive, action: reset)
                            .font(.subheadline)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
            }
            .navigationTitle("記録")
            .alert("記録を保存しますか？", isPresented: $showSaveAlert) {
                Button("保存") { saveRecord() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("\(jumpCount)回 / \(timeString(elapsedTime))")
            }
            .task {
                await healthKit.requestAuthorization()
            }
        }
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        jumpDetector.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            elapsedTime += 0.1
        }
    }

    private func stopRecording() {
        isRecording = false
        jumpDetector.stop()
        timer?.invalidate()
        timer = nil
        if elapsedTime > 0 { showSaveAlert = true }
    }

    private func saveRecord() {
        let record = WorkoutRecord(
            duration: elapsedTime,
            jumpCount: jumpCount,
            calories: calories
        )
        modelContext.insert(record)
        Task { try? await healthKit.saveWorkout(record: record) }
        reset()
    }

    private func reset() {
        elapsedTime = 0
        jumpDetector.reset()
    }

    private func timeString(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
                .contentTransition(.numericText())
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 80)
    }
}

#Preview {
    RecordView()
        .modelContainer(for: WorkoutRecord.self, inMemory: true)
}

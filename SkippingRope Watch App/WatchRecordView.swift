import SwiftUI
import SwiftData
import HealthKit
import CoreMotion

// MARK: - Model

@Model
final class WatchWorkoutRecord {
    var date: Date = Date()
    var duration: TimeInterval = 0
    var jumpCount: Int = 0
    var calories: Double = 0

    init(date: Date, duration: TimeInterval, jumpCount: Int, calories: Double) {
        self.date = date
        self.duration = duration
        self.jumpCount = jumpCount
        self.calories = calories
    }

    var jumpsPerMinute: Double {
        guard duration > 0 else { return 0 }
        return Double(jumpCount) / (duration / 60)
    }
}

// MARK: - Workout Manager

@Observable
final class WatchWorkoutManager: NSObject {
    private let healthStore = HKHealthStore()
    private let motionManager = CMMotionManager()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var clockTimer: Timer?

    var isRunning = false
    var elapsedTime: TimeInterval = 0
    var jumpCount = 0
    var calories: Double = 0
    private var bodyWeightKg: Double = 60.0

    private let threshold: Double = 1.7
    private let minimumJumpInterval: TimeInterval = 0.3
    private var wasAboveThreshold = false
    private var lastJumpTime: Date = .distantPast

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let shareTypes: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.activeEnergyBurned)
        ]
        let readTypes: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.bodyMass)
        ]
        try? await healthStore.requestAuthorization(toShare: shareTypes, read: readTypes)
        await fetchBodyWeight()
    }

    func fetchBodyWeight() async {
        let type = HKQuantityType(.bodyMass)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { [weak self] _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else { return }
            let kg = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
            DispatchQueue.main.async {
                self?.bodyWeightKg = kg
            }
        }
        healthStore.execute(query)
    }

    func start() {
        let config = HKWorkoutConfiguration()
        config.activityType = .jumpRope
        config.locationType = .indoor

        do {
            let newSession = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let newBuilder = newSession.associatedWorkoutBuilder()
            newBuilder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: config
            )
            newSession.delegate = self
            newBuilder.delegate = self
            session = newSession
            builder = newBuilder

            let now = Date()
            newSession.startActivity(with: now)
            newBuilder.beginCollection(withStart: now) { _, _ in }
        } catch {
            print("Failed to start workout session: \(error)")
        }

        jumpCount = 0
        elapsedTime = 0
        calories = 0
        wasAboveThreshold = false
        lastJumpTime = .distantPast
        isRunning = true

        clockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsedTime += 0.5
            self.calories = 11.0 * self.bodyWeightKg * (self.elapsedTime / 3600)
        }

        startAccelerometer()
    }

    func stop() {
        isRunning = false
        clockTimer?.invalidate()
        clockTimer = nil
        motionManager.stopAccelerometerUpdates()

        let now = Date()
        session?.end()
        builder?.endCollection(withEnd: now) { [weak self] _, _ in
            self?.builder?.finishWorkout { _, _ in }
        }
    }

    func save(context: ModelContext) {
        let record = WatchWorkoutRecord(
            date: Date(),
            duration: elapsedTime,
            jumpCount: jumpCount,
            calories: calories
        )
        context.insert(record)
        reset()
    }

    func reset() {
        elapsedTime = 0
        jumpCount = 0
        calories = 0
        wasAboveThreshold = false
        lastJumpTime = .distantPast
    }

    private func startAccelerometer() {
        guard motionManager.isAccelerometerAvailable else { return }
        motionManager.accelerometerUpdateInterval = 1.0 / 50.0
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.process(data.acceleration)
        }
    }

    private func process(_ acc: CMAcceleration) {
        let magnitude = (acc.x * acc.x + acc.y * acc.y + acc.z * acc.z).squareRoot()

        if magnitude > threshold {
            if !wasAboveThreshold {
                let now = Date()
                if now.timeIntervalSince(lastJumpTime) >= minimumJumpInterval {
                    lastJumpTime = now
                    jumpCount += 1
                }
            }
            wasAboveThreshold = true
        } else {
            wasAboveThreshold = false
        }
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        print("Workout session error: \(error)")
    }
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {}

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - Record View

struct WatchRecordView: View {
    @State private var manager = WatchWorkoutManager()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "figure.jumprope")
                    .font(.system(size: 24))
                    .foregroundStyle(manager.isRunning ? .blue : .gray)
                    .symbolEffect(.variableColor.iterative, isActive: manager.isRunning)

                Text(timeString(manager.elapsedTime))
                    .font(.system(size: 28, weight: .thin, design: .monospaced))
                    .foregroundStyle(manager.isRunning ? .primary : .secondary)
            }

            HStack(spacing: 20) {
                VStack(spacing: 0) {
                    Text("\(manager.jumpCount)")
                        .font(.title3.bold())
                    Text("回")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    Text(String(format: "%.0f", manager.calories))
                        .font(.title3.bold())
                    Text("kcal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Button(manager.isRunning ? "停止" : "開始") {
                if manager.isRunning { manager.stop() } else { manager.start() }
            }
            .tint(manager.isRunning ? .red : .green)
            .buttonStyle(.bordered)

            if !manager.isRunning && manager.elapsedTime > 0 {
                HStack(spacing: 8) {
                    Button("保存") {
                        manager.save(context: modelContext)
                    }
                    .tint(.blue)
                    .buttonStyle(.bordered)
                    .font(.footnote)

                    Button("リセット", role: .destructive) {
                        manager.reset()
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                }
            }
        }
        .navigationBarHidden(true)
        .task {
            await manager.requestAuthorization()
        }
    }

    private func timeString(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - History View

struct WatchHistoryView: View {
    @Query(sort: \WatchWorkoutRecord.date, order: .reverse) private var records: [WatchWorkoutRecord]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "figure.jumprope")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("記録がありません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        ForEach(records) { record in
                            WatchWorkoutRow(record: record)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                modelContext.delete(records[index])
                            }
                        }
                    }
                    .listStyle(.carousel)
                }
            }
            .navigationTitle("履歴")
        }
    }
}

struct WatchWorkoutRow: View {
    let record: WatchWorkoutRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Label("\(record.jumpCount)", systemImage: "figure.jumprope")
                Label(timeString(record.duration), systemImage: "clock")
            }
            .font(.caption)
            HStack(spacing: 8) {
                Label(String(format: "%.0f kcal", record.calories), systemImage: "flame.fill")
                    .foregroundStyle(.orange)
                Text(String(format: "%.0f/分", record.jumpsPerMinute))
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
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
    NavigationStack {
        WatchRecordView()
    }
}

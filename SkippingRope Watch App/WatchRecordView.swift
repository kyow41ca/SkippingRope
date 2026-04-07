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
    var averageHeartRate: Double = 0

    init(date: Date, duration: TimeInterval, jumpCount: Int, calories: Double, averageHeartRate: Double = 0) {
        self.date = date
        self.duration = duration
        self.jumpCount = jumpCount
        self.calories = calories
        self.averageHeartRate = averageHeartRate
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
    var isPaused = false
    var elapsedTime: TimeInterval = 0
    var jumpCount = 0
    var calories: Double = 0
    var heartRate: Double = 0
    var averageHeartRate: Double = 0

    private let threshold: Double = 1.7
    private let minimumJumpInterval: TimeInterval = 0.3
    private var wasAboveThreshold = false
    private var lastJumpTime: Date = .distantPast

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let shareTypes: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.heartRate)
        ]
        let readTypes: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.heartRate)
        ]
        try? await healthStore.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    func start() {
        let config = HKWorkoutConfiguration()
        config.activityType = .jumpRope
        config.locationType = .indoor

        do {
            let newSession = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let newBuilder = newSession.associatedWorkoutBuilder()
            let dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: config
            )
            dataSource.enableCollection(for: HKQuantityType(.heartRate), predicate: nil)
            newBuilder.dataSource = dataSource
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
        heartRate = 0
        averageHeartRate = 0
        wasAboveThreshold = false
        lastJumpTime = .distantPast
        isRunning = true

        clockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsedTime = self.builder?.elapsedTime(at: Date()) ?? 0
        }

        startAccelerometer()
    }

    func pause() {
        clockTimer?.invalidate()
        clockTimer = nil
        motionManager.stopAccelerometerUpdates()
        session?.pause()
    }

    func resume() {
        session?.resume()
    }

    func save(context: ModelContext) {
        let record = WatchWorkoutRecord(
            date: Date(),
            duration: elapsedTime,
            jumpCount: jumpCount,
            calories: calories,
            averageHeartRate: averageHeartRate
        )
        context.insert(record)
        endSessionAndReset()
    }

    func reset() {
        endSessionAndReset()
    }

    private func endSessionAndReset() {
        isRunning = false
        isPaused = false
        clockTimer?.invalidate()
        clockTimer = nil
        motionManager.stopAccelerometerUpdates()

        let now = Date()
        session?.end()
        builder?.endCollection(withEnd: now) { [weak self] _, _ in
            self?.builder?.finishWorkout { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.session = nil
                    self?.builder = nil
                }
            }
        }

        elapsedTime = 0
        jumpCount = 0
        calories = 0
        heartRate = 0
        averageHeartRate = 0
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
    ) {
        Task { @MainActor in
            switch toState {
            case .paused:
                isRunning = false
                isPaused = true
                clockTimer?.invalidate()
                clockTimer = nil
                motionManager.stopAccelerometerUpdates()
            case .running:
                isRunning = true
                isPaused = false
                startAccelerometer()
                clockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.elapsedTime = self.builder?.elapsedTime(at: Date()) ?? 0
                }
            default:
                break
            }
        }
    }

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
    ) {
        var newCalories: Double?
        var newHeartRate: Double?

        if collectedTypes.contains(HKQuantityType(.activeEnergyBurned)) {
            newCalories = workoutBuilder.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie())
        }
        if collectedTypes.contains(HKQuantityType(.heartRate)) {
            let stats = workoutBuilder.statistics(for: HKQuantityType(.heartRate))
            let unit = HKUnit.count().unitDivided(by: .minute())
            newHeartRate = stats?.mostRecentQuantity()?.doubleValue(for: unit)
            let avg = stats?.averageQuantity()?.doubleValue(for: unit)
            DispatchQueue.main.async {
                if let bpm = newHeartRate { self.heartRate = bpm }
                if let avg { self.averageHeartRate = avg }
            }
        }

        DispatchQueue.main.async {
            if let kcal = newCalories { self.calories = kcal }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - Record View

struct WatchRecordView: View {
    var manager: WatchWorkoutManager
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "figure.jumprope")
                    .font(.system(size: 24))
                    .foregroundStyle(manager.isRunning ? .blue : .gray)

                Text(timeString(manager.elapsedTime))
                    .font(.system(size: 28, weight: .thin, design: .monospaced))
                    .foregroundStyle(manager.isRunning ? .primary : .secondary)
            }

            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    Text("\(manager.jumpCount)")
                        .font(.title3.bold())
                    Text("jumps")
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
                VStack(spacing: 0) {
                    HStack(spacing: 2) {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                        Text(manager.heartRate > 0 ? String(format: "%.0f", manager.heartRate) : "--")
                            .font(.title3.bold())
                    }
                    Text("bpm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if manager.isRunning {
                Button("Pause") { manager.pause() }
                    .tint(.orange)
                    .buttonStyle(.bordered)
            } else if manager.isPaused {
                Button("Resume") { manager.resume() }
                    .tint(.green)
                    .buttonStyle(.bordered)
                Button("Save") { manager.save(context: modelContext) }
                    .tint(.blue)
                    .buttonStyle(.bordered)
            } else {
                Button("Start") { manager.start() }
                    .tint(.green)
                    .buttonStyle(.bordered)
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
                        Text("No Records")
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
            .navigationTitle("History")
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
                if record.averageHeartRate > 0 {
                    Label(String(format: "%.0f bpm", record.averageHeartRate), systemImage: "heart.fill")
                        .foregroundStyle(.red)
                }
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
        WatchRecordView(manager: WatchWorkoutManager())
    }
}

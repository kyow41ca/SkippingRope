import SwiftUI
import HealthKit
import CoreMotion

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

    // ジャンプ検出パラメータ（iOS版と共通）
    private let threshold: Double = 1.7
    private let minimumJumpInterval: TimeInterval = 0.3
    private var wasAboveThreshold = false
    private var lastJumpTime: Date = .distantPast

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let types: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.activeEnergyBurned)
        ]
        try? await healthStore.requestAuthorization(toShare: types, read: types)
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
            self.calories = 11.0 * 60.0 * (self.elapsedTime / 3600)
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

// MARK: - View

struct WatchRecordView: View {
    @State private var manager = WatchWorkoutManager()

    var body: some View {
        VStack(spacing: 4) {
            Text(timeString(manager.elapsedTime))
                .font(.system(size: 32, weight: .thin, design: .monospaced))
                .foregroundStyle(manager.isRunning ? .primary : .secondary)

            HStack(spacing: 16) {
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

            HStack(spacing: 8) {
                // 手動 -1（誤検知補正）
                Button {
                    if manager.jumpCount > 0 { manager.jumpCount -= 1 }
                } label: {
                    Image(systemName: "minus")
                        .font(.caption.bold())
                }
                .disabled(!manager.isRunning)
                .tint(.red)

                Button(manager.isRunning ? "停止" : "開始") {
                    if manager.isRunning { manager.stop() } else { manager.start() }
                }
                .tint(manager.isRunning ? .red : .green)

                // 手動 +1（拾い損ね補正）
                Button {
                    if manager.isRunning { manager.jumpCount += 1 }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.bold())
                }
                .disabled(!manager.isRunning)
                .tint(.blue)
            }
            .buttonStyle(.bordered)
        }
        .navigationTitle("記録")
        .navigationBarTitleDisplayMode(.inline)
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

#Preview {
    NavigationStack {
        WatchRecordView()
    }
}

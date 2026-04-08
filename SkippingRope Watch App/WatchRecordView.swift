import SwiftUI
import SwiftData
import HealthKit
import CoreMotion
import WatchKit

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

// MARK: - Goal

enum WorkoutGoal: Hashable {
    case none
    case jumps(Int)
    case time(TimeInterval)
    case calories(Double)
}

enum GoalKind: Hashable {
    case jumps, time, calories

    var localizedLabel: LocalizedStringKey {
        switch self {
        case .jumps: "Jump Count"
        case .time: "Time"
        case .calories: "Calories"
        }
    }

    var defaultValue: Double {
        switch self {
        case .jumps: 100
        case .time: 300
        case .calories: 100
        }
    }

    var buttonStep: Double {
        switch self {
        case .jumps: 10
        case .time: 60
        case .calories: 10
        }
    }

    var minValue: Double {
        switch self {
        case .jumps: 10
        case .time: 60
        case .calories: 10
        }
    }

    var maxValue: Double {
        switch self {
        case .jumps: 9_990
        case .time: 5_940    // 99 min
        case .calories: 9_990
        }
    }

    func formatted(_ value: Double) -> String {
        switch self {
        case .jumps: return "\(Int(value))"
        case .time:
            let m = Int(value) / 60
            let s = Int(value) % 60
            return s == 0 ? "\(m):00" : String(format: "%d:%02d", m, s)
        case .calories: return "\(Int(value))"
        }
    }

    func makeGoal(_ value: Double) -> WorkoutGoal {
        switch self {
        case .jumps: return .jumps(Int(value))
        case .time: return .time(value)
        case .calories: return .calories(value)
        }
    }

}


// MARK: - Workout Manager

@Observable
final class WatchWorkoutManager: NSObject {
    private let healthStore = HKHealthStore()
    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private var motionAboveThreshold = false
    private var motionLastJumpTime: Date = .distantPast
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var clockTimer: Timer?

    var isRunning = false
    var isPaused = false
    var isCountingDown = false
    var countdownValue = 3
    private var countdownTimer: Timer?
    var elapsedTime: TimeInterval = 0
    var jumpCount = 0
    var calories: Double = 0
    var heartRate: Double = 0
    var averageHeartRate: Double = 0

    var goal: WorkoutGoal = .none
    var showingGoalAchievement = false
    private var goalAchievedOnce = false

    private let threshold: Double = 1.7
    private let minimumJumpInterval: TimeInterval = 0.3

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

    func beginCountdown() {
        isCountingDown = true
        countdownValue = 3
        WKInterfaceDevice.current().play(.notification)

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.countdownValue -= 1
            if self.countdownValue <= 0 {
                self.countdownTimer?.invalidate()
                self.countdownTimer = nil
                self.isCountingDown = false
                WKInterfaceDevice.current().play(.directionUp)
                self.start()
            } else {
                WKInterfaceDevice.current().play(.notification)
            }
        }
    }

    func skipCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        isCountingDown = false
        WKInterfaceDevice.current().play(.directionUp)
        start()
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
        motionAboveThreshold = false
        motionLastJumpTime = .distantPast
        goalAchievedOnce = false
        isRunning = true

        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsedTime = self.builder?.elapsedTime(at: Date()) ?? 0
            self.checkGoal()
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

    func end(context: ModelContext) {
        if elapsedTime >= 30 {
            let record = WatchWorkoutRecord(
                date: Date(),
                duration: elapsedTime,
                jumpCount: jumpCount,
                calories: calories,
                averageHeartRate: averageHeartRate
            )
            context.insert(record)
            WKInterfaceDevice.current().play(.success)
        }
        endSessionAndReset()
    }

    private func checkGoal() {
        guard !goalAchievedOnce, isRunning else { return }
        let achieved: Bool
        switch goal {
        case .none: return
        case .jumps(let t): achieved = jumpCount >= t
        case .time(let t): achieved = elapsedTime >= t
        case .calories(let t): achieved = calories >= t
        }
        guard achieved else { return }
        goalAchievedOnce = true
        showingGoalAchievement = true
        WKInterfaceDevice.current().play(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.showingGoalAchievement = false
        }
    }

    private func endSessionAndReset() {
        isRunning = false
        isPaused = false
        isCountingDown = false
        countdownTimer?.invalidate()
        countdownTimer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        motionManager.stopAccelerometerUpdates()
        showingGoalAchievement = false
        goalAchievedOnce = false
        goal = .none

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
        motionAboveThreshold = false
        motionLastJumpTime = .distantPast
    }

    private func startAccelerometer() {
        guard motionManager.isAccelerometerAvailable else { return }
        motionManager.accelerometerUpdateInterval = 1.0 / 50.0
        motionManager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, _ in
            guard let self, let data else { return }
            self.process(data.acceleration)
        }
    }

    private func process(_ acc: CMAcceleration) {
        let magnitude = (acc.x * acc.x + acc.y * acc.y + acc.z * acc.z).squareRoot()

        if magnitude > threshold {
            if !motionAboveThreshold {
                let now = Date()
                if now.timeIntervalSince(motionLastJumpTime) >= minimumJumpInterval {
                    motionLastJumpTime = now
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.jumpCount += 1
                        self.checkGoal()
                    }
                }
            }
            motionAboveThreshold = true
        } else {
            motionAboveThreshold = false
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
                clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.elapsedTime = self.builder?.elapsedTime(at: Date()) ?? 0
                    self.checkGoal()
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
            if let kcal = newCalories {
                self.calories = kcal
                self.checkGoal()
            }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - Record View

struct WatchRecordView: View {
    var manager: WatchWorkoutManager
    @Environment(\.modelContext) private var modelContext
    @State private var showingGoalSheet = false

    var body: some View {
        VStack(spacing: 4) {
            if manager.isRunning || manager.isPaused {
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
            } else {
                Image(systemName: "figure.jumprope")
                    .font(.system(size: 40))
                    .foregroundStyle(.gray)
            }

            if manager.isRunning {
                Button("Pause") { manager.pause() }
                    .tint(.orange)
                    .buttonStyle(.bordered)
            } else if manager.isPaused {
                Button("Resume") { manager.resume() }
                    .tint(.green)
                    .buttonStyle(.bordered)
                Button("End") { manager.end(context: modelContext) }
                    .tint(.red)
                    .buttonStyle(.bordered)
            } else {
                Button("Start") {
                    manager.goal = .none
                    manager.beginCountdown()
                }
                .tint(.green)
                .buttonStyle(.bordered)
                Button("Goal") { showingGoalSheet = true }
                    .tint(.blue)
                    .buttonStyle(.bordered)
            }
        }
        .sheet(isPresented: $showingGoalSheet) {
            NavigationStack {
                GoalSelectionView(manager: manager, isSheetPresented: $showingGoalSheet)
            }
        }
        .overlay {
            if manager.isCountingDown {
                CountdownOverlay(value: manager.countdownValue, onSkip: manager.skipCountdown)
            }
            if manager.showingGoalAchievement {
                GoalAchievedOverlay(goal: manager.goal)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: manager.showingGoalAchievement)
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

// MARK: - Goal Selection View

struct GoalSelectionView: View {
    var manager: WatchWorkoutManager
    @Binding var isSheetPresented: Bool

    var body: some View {
        List {
            NavigationLink(String(localized: "Jump Count")) {
                GoalValueView(manager: manager, kind: .jumps, isSheetPresented: $isSheetPresented)
            }
            NavigationLink(String(localized: "Time")) {
                GoalValueView(manager: manager, kind: .time, isSheetPresented: $isSheetPresented)
            }
            NavigationLink(String(localized: "Calories")) {
                GoalValueView(manager: manager, kind: .calories, isSheetPresented: $isSheetPresented)
            }
        }
        .navigationTitle("Goal")
    }
}

// MARK: - Goal Value View

struct GoalValueView: View {
    var manager: WatchWorkoutManager
    let kind: GoalKind
    @Binding var isSheetPresented: Bool
    @State private var value: Double

    private var values: [Double] {
        Array(stride(from: kind.minValue, through: kind.maxValue, by: kind.buttonStep))
    }

    init(manager: WatchWorkoutManager, kind: GoalKind, isSheetPresented: Binding<Bool>) {
        self.manager = manager
        self.kind = kind
        self._isSheetPresented = isSheetPresented
        self._value = State(initialValue: kind.defaultValue)
    }

    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: $value) {
                ForEach(values, id: \.self) { v in
                    Text(kind.formatted(v)).tag(v)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()

            Button("Start") {
                manager.goal = kind.makeGoal(value)
                isSheetPresented = false
                manager.beginCountdown()
            }
            .tint(.green)
            .buttonStyle(.bordered)
        }
        .navigationTitle(kind.localizedLabel)
    }
}

// MARK: - Goal Achieved Overlay

struct GoalAchievedOverlay: View {
    let goal: WorkoutGoal

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 8) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.yellow)
                Text("Goal Achieved!")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(goalText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var goalText: String {
        switch goal {
        case .none: return ""
        case .jumps(let n): return "\(n) " + String(localized: "jumps")
        case .time(let t):
            let m = Int(t) / 60; let s = Int(t) % 60
            return s == 0 ? "\(m):00" : String(format: "%d:%02d", m, s)
        case .calories(let c): return "\(Int(c)) kcal"
        }
    }
}

// MARK: - Countdown Overlay

struct CountdownOverlay: View {
    let value: Int
    let onSkip: () -> Void
    @State private var trimEnd: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 4)
                        .frame(width: 88, height: 88)
                    Circle()
                        .trim(from: 0, to: trimEnd)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 88, height: 88)
                    Text("\(value)")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .id(value)
                        .transition(.scale(scale: 1.4).combined(with: .opacity))
                        .animation(.easeOut(duration: 0.25), value: value)
                }
                Text("Tap to skip", tableName: "Localizable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.0)) { trimEnd = 1.0 / 3.0 }
        }
        .onChange(of: value) { _, newValue in
            let target = CGFloat(3 - newValue + 1) / 3.0
            withAnimation(.linear(duration: 1.0)) { trimEnd = target }
        }
        .onTapGesture(perform: onSkip)
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
    WatchRecordView(manager: WatchWorkoutManager())
}

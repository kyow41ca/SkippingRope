import Foundation
import HealthKit

@Observable
final class HealthKitService {
    private let store = HKHealthStore()
    var isAuthorized = false
    var bodyWeightKg: Double = 60.0  // デフォルト60kg、取得できれば上書き

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let writeTypes: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.activeEnergyBurned)
        ]
        let readTypes: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.bodyMass)
        ]

        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            isAuthorized = true
            await fetchBodyWeight()
        } catch {
            print("HealthKit authorization failed: \(error)")
        }
    }

    func fetchBodyWeight() async {
        let type = HKQuantityType(.bodyMass)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { [weak self] _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else { return }
            let kg = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
            Task { @MainActor in
                self?.bodyWeightKg = kg
            }
        }
        store.execute(query)
    }

    func saveWorkout(record: WorkoutRecord) async throws {
        let startDate = record.date
        let endDate = startDate.addingTimeInterval(record.duration)

        let config = HKWorkoutConfiguration()
        config.activityType = .jumpRope
        config.locationType = .indoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            builder.beginCollection(withStart: startDate) { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }

        let energySample = HKQuantitySample(
            type: HKQuantityType(.activeEnergyBurned),
            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: record.calories),
            start: startDate,
            end: endDate
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            builder.add([energySample]) { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            builder.endCollection(withEnd: endDate) { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }

        _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HKWorkout?, Error>) in
            builder.finishWorkout { workout, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: workout) }
            }
        }
    }
}

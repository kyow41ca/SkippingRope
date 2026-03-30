import Foundation
import SwiftData

@Model
final class WorkoutRecord {
    var id: UUID
    var date: Date
    var duration: TimeInterval
    var jumpCount: Int
    var calories: Double
    var notes: String

    init(
        date: Date = .now,
        duration: TimeInterval,
        jumpCount: Int,
        calories: Double,
        notes: String = ""
    ) {
        self.id = UUID()
        self.date = date
        self.duration = duration
        self.jumpCount = jumpCount
        self.calories = calories
        self.notes = notes
    }

    var jumpsPerMinute: Double {
        guard duration > 0 else { return 0 }
        return Double(jumpCount) / (duration / 60)
    }

    static func calculateCalories(duration: TimeInterval, weightKg: Double = 60) -> Double {
        // なわとびのMET値 ≈ 11
        let met = 11.0
        let hours = duration / 3600
        return met * weightKg * hours
    }
}

import Foundation
import WatchConnectivity
import SwiftData

@Observable
final class ConnectivityManager: NSObject {
    static let shared = ConnectivityManager()

    var modelContext: ModelContext?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
}

extension ConnectivityManager: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        save(userInfo: message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        save(userInfo: message)
        replyHandler(["status": "ok"])
    }

    // Watch からのデータを受け取り SwiftData に保存
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        save(userInfo: userInfo)
    }

    private func save(userInfo: [String: Any]) {
        guard
            let jumpCount = userInfo["jumpCount"] as? Int,
            let duration = userInfo["duration"] as? Double,
            let calories = userInfo["calories"] as? Double,
            let dateInterval = userInfo["date"] as? Double
        else { return }

        Task { @MainActor in
            guard let context = modelContext else { return }
            let record = WorkoutRecord(
                date: Date(timeIntervalSince1970: dateInterval),
                duration: duration,
                jumpCount: jumpCount,
                calories: calories
            )
            context.insert(record)
            try? context.save()
        }
    }
}

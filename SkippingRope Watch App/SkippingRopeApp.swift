import SwiftUI
import WatchConnectivity

@main
struct SkippingRope_Watch_AppApp: App {
    private let sessionDelegate = WatchSessionDelegate()

    init() {
        sessionDelegate.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// Watch は送信専用なので delegate は最小限
final class WatchSessionDelegate: NSObject, WCSessionDelegate {
    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}
}

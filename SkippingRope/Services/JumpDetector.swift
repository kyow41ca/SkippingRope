import CoreMotion
import Foundation

@Observable
final class JumpDetector {
    private let motionManager = CMMotionManager()

    var jumpCount = 0
    var isAvailable: Bool { motionManager.isAccelerometerAvailable }

    // ジャンプ検出パラメータ
    // 静止時の magnitude ≈ 1.0g。なわとび時は着地・跳躍で 1.7g 超えが来る
    private let threshold: Double = 1.7
    // 連続カウント防止（最大 200回/分 = 0.3秒間隔）
    private let minimumJumpInterval: TimeInterval = 0.3

    private var wasAboveThreshold = false
    private var lastJumpTime: Date = .distantPast

    func start() {
        guard motionManager.isAccelerometerAvailable else { return }
        jumpCount = 0
        wasAboveThreshold = false
        lastJumpTime = .distantPast

        motionManager.accelerometerUpdateInterval = 1.0 / 50.0  // 50Hz
        // メインスレッドで受け取ることで Swift 6 の actor 隔離問題を回避
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.process(data.acceleration)
        }
    }

    func stop() {
        motionManager.stopAccelerometerUpdates()
    }

    func reset() {
        jumpCount = 0
        wasAboveThreshold = false
        lastJumpTime = .distantPast
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

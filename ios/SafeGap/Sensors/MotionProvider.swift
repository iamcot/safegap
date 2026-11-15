// Góc ngẩng camera từ CoreMotion (trọng lực đã tách khỏi gia tốc xe nhờ sensor fusion).
import CoreMotion
import Foundation
import SafeGapCore

final class MotionProvider {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var pitch: Double?
    private var at: Date?

    var available: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        queue.maxConcurrentOperationCount = 1
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] m, _ in
            guard let self, let g = m?.gravity else { return }
            let p = Horizon.cameraPitch(gravityX: g.x, gravityY: g.y, gravityZ: g.z)
            self.lock.lock()
            self.pitch = p
            self.at = Date()
            self.lock.unlock()
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    /// Góc ngẩng (rad), nil nếu chưa có hoặc quá cũ.
    func currentPitch(maxAge: TimeInterval = 0.5) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = pitch, let at, Date().timeIntervalSince(at) <= maxAge else { return nil }
        return p
    }
}

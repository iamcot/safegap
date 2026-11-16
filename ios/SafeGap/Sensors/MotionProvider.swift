// Góc ngẩng camera từ CoreMotion (trọng lực đã tách khỏi gia tốc xe nhờ sensor fusion),
// và tốc độ quay quanh trục thẳng đứng (gyro chiếu lên trọng lực) để phát hiện xe rẽ.
import CoreMotion
import Foundation
import SafeGapCore

final class MotionProvider {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var pitch: Double?
    private var yawRate: Double?
    private var at: Date?

    var available: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        queue.maxConcurrentOperationCount = 1
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] m, _ in
            guard let self, let m else { return }
            let g = m.gravity, r = m.rotationRate
            let p = Horizon.cameraPitch(gravityX: g.x, gravityY: g.y, gravityZ: g.z)
            // Thành phần quay quanh hướng trọng lực (hướng xuống): dương = theo chiều kim đồng hồ nhìn từ trên = rẽ phải.
            let gn = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            let yaw: Double? = gn > 0.5 ? (r.x * g.x + r.y * g.y + r.z * g.z) / gn * 180 / .pi : nil
            self.lock.lock()
            self.pitch = p
            self.yawRate = yaw
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

    /// Tốc độ quay quanh trục thẳng đứng (°/s, dương = rẽ phải), nil nếu chưa có hoặc quá cũ.
    func currentYawRate(maxAge: TimeInterval = 0.5) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let y = yawRate, let at, Date().timeIntervalSince(at) <= maxAge else { return nil }
        return y
    }
}

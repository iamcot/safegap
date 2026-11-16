// Giảm tần số xử lý khi máy nóng (Phase 3). Tách khỏi UIKit để test được.
import Foundation

/// Giống ProcessInfo.ThermalState nhưng không phụ thuộc nền tảng.
public enum ThermalLevel: String, Codable, Sendable, CaseIterable {
    case nominal, fair, serious, critical
}

public struct ThermalPolicy: Equatable, Sendable {
    /// fps mục tiêu theo mức nhiệt. Mặc định: 30 → 20 → 12 → 6.
    public var fps: [ThermalLevel: Double]

    public init(fps: [ThermalLevel: Double] = [.nominal: 30, .fair: 20, .serious: 12, .critical: 6]) {
        self.fps = fps
    }

    /// Chế độ chạy mát: 15 fps là đủ cho cảnh báo khoảng cách, giảm tiếp khi nóng.
    public static let cool = ThermalPolicy(fps: [.nominal: 15, .fair: 12, .serious: 8, .critical: 5])

    public func targetFps(_ level: ThermalLevel) -> Double {
        fps[level] ?? 30
    }
}

/// Bỏ bớt frame để đạt fps mục tiêu (bình quân đúng mục tiêu). Dùng thời gian của frame (giây), không dùng đồng hồ máy.
public struct FrameThrottle: Equatable, Sendable {
    public private(set) var nextDue: Double?
    /// Cho phép sớm hơn hạn một phần chu kỳ (thời gian frame có nhiễu vài ms).
    public var tolerance: Double

    public init(tolerance: Double = 0.25) { self.tolerance = tolerance }

    public mutating func shouldProcess(t: Double, targetFps: Double) -> Bool {
        guard targetFps > 0 else { return false }
        let period = 1.0 / targetFps
        // lần đầu, thời gian tua lại (camera khởi động lại) hoặc tụt lại quá xa: bắt đầu lại từ frame này
        guard let due = nextDue, t >= due - 2 * period, t < due + period else {
            nextDue = t + period
            return true
        }
        if t >= due - tolerance * period {
            nextDue = due + period
            return true
        }
        return false
    }
}

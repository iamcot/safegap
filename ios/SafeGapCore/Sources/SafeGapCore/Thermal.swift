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

    public func targetFps(_ level: ThermalLevel) -> Double {
        fps[level] ?? 30
    }
}

/// Bỏ bớt frame để đạt fps mục tiêu. Dùng thời gian của frame (giây), không dùng đồng hồ máy.
public struct FrameThrottle: Equatable, Sendable {
    public private(set) var lastProcessed: Double?
    /// Cho phép sớm hơn chu kỳ một chút để camera 30 fps vẫn xử lý đủ 30 (thời gian frame có nhiễu).
    public var tolerance: Double

    public init(tolerance: Double = 0.25) { self.tolerance = tolerance }

    public mutating func shouldProcess(t: Double, targetFps: Double) -> Bool {
        guard targetFps > 0 else { return false }
        if let last = lastProcessed, t > last, t - last < (1.0 - tolerance) / targetFps {
            return false
        }
        lastProcessed = t
        return true
    }
}

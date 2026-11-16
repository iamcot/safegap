// Sự kiện trên đường dùng chung cho biển báo / đèn / cảnh báo: quãng đường đã đi, đứng yên, rẽ, qua ngã tư.
// Xem docs/DRIVER_ASSIST.md (A1).
import Foundation

/// Quãng đường tích luỹ (m) từ tốc độ, để đo "đã đi bao xa từ lúc thấy biển".
public struct Odometer: Equatable, Sendable {
    public private(set) var meters: Double = 0
    private var lastT: Double?
    /// Khoảng trống dài hơn (s) thì không cộng (mất GPS, app chạy nền).
    public var maxGapS: Double

    public init(maxGapS: Double = 2) { self.maxGapS = maxGapS }

    @discardableResult
    public mutating func update(t: Double, speedKmh: Double?) -> Double {
        defer { lastT = t }
        guard let last = lastT, let v = speedKmh, v > 0 else { return meters }
        let dt = t - last
        guard dt > 0, dt <= maxGapS else { return meters }
        meters += v / 3.6 * dt
        return meters
    }
}

/// Đứng yên: dưới `stopKmh` là dừng, trên `goKmh` mới tính là chạy lại (chống nhấp nháy khi GPS dao động).
public struct StopDetector: Equatable, Sendable {
    public var stopKmh: Double
    public var goKmh: Double
    public private(set) var stoppedSince: Double?

    public init(stopKmh: Double = 3, goKmh: Double = 6) {
        self.stopKmh = stopKmh
        self.goKmh = goKmh
    }

    public var isStopped: Bool { stoppedSince != nil }

    /// Trả về số giây đã đứng yên (nil nếu đang chạy hoặc chưa có tốc độ).
    @discardableResult
    public mutating func update(t: Double, speedKmh: Double?) -> Double? {
        guard let v = speedKmh else { return stoppedSince.map { t - $0 } }
        if let since = stoppedSince {
            if v > goKmh { stoppedSince = nil; return nil }
            return t - since
        }
        if v < stopKmh { stoppedSince = t; return 0 }
        return nil
    }
}

public enum TurnDirection: String, Codable, Sendable {
    case left, right, uturn
}

public struct TurnEvent: Equatable, Sendable {
    public var direction: TurnDirection
    /// Góc đã quay (độ, dương = theo chiều kim đồng hồ nhìn từ trên = rẽ phải).
    public var angleDeg: Double
    public var t: Double

    public init(direction: TurnDirection, angleDeg: Double, t: Double) {
        self.direction = direction
        self.angleDeg = angleDeg
        self.t = t
    }
}

/// Phát hiện rẽ trái / phải / quay đầu từ hướng xe.
/// Nguồn hướng: tích phân tốc độ quay quanh trục thẳng đứng (gyro, °/s, dương = theo chiều kim đồng hồ),
/// không có gyro thì dùng hướng GPS (course, 0 = bắc, tăng theo chiều kim đồng hồ).
public struct TurnDetector: Equatable, Sendable {
    /// Quay ≥ góc này trong cửa sổ thời gian là một lần rẽ.
    public var minTurnDeg: Double = 60
    public var uturnDeg: Double = 150
    public var windowS: Double = 12
    /// Đang quay nhanh hơn mức này (°/s, trung bình 1,5 s) là "đang rẽ".
    public var turningRateDegS: Double = 8
    /// Xe chậm hơn mức này thì không tính (xoay máy khi đứng yên, quay vô lăng tại chỗ).
    public var minSpeedKmh: Double = 3

    struct Sample: Equatable, Sendable { var t: Double; var heading: Double }

    private var samples: [Sample] = []
    private var heading = 0.0
    private var lastT: Double?
    private var lastCourse: Double?
    public private(set) var turning: TurnDirection?
    public private(set) var lastTurn: TurnEvent?

    public init() {}

    /// Hướng tích luỹ (độ, không quấn về 0..360).
    public var unwrappedHeading: Double { heading }

    public mutating func reset() {
        samples.removeAll()
        lastCourse = nil
        turning = nil
    }

    /// Gọi mỗi frame. Trả về sự kiện khi vừa hoàn thành một lần rẽ.
    public mutating func update(t: Double, yawRateDegS: Double?, courseDeg: Double?, speedKmh: Double?) -> TurnEvent? {
        let dt = lastT.map { t - $0 } ?? 0
        lastT = t
        if let r = yawRateDegS {
            if dt > 0, dt < 1 { heading += r * dt }
            lastCourse = nil
        } else if let c = courseDeg {
            if let prev = lastCourse { heading += Self.angleDiff(c, prev) }
            lastCourse = c
        }
        guard let v = speedKmh, v >= minSpeedKmh else {
            // đứng yên: giữ cửa sổ nhưng không thêm mẫu (rẽ khi đang nhích vẫn tính khi chạy lại)
            turning = nil
            return nil
        }
        samples.append(Sample(t: t, heading: heading))
        let window = windowS
        samples.removeAll { t - $0.t > window }

        // đang rẽ: tốc độ quay trung bình 1,5 s gần nhất
        if let recent = samples.first(where: { t - $0.t <= 1.5 }), t - recent.t > 0.5 {
            let rate = (heading - recent.heading) / (t - recent.t)
            turning = abs(rate) >= turningRateDegS ? (rate > 0 ? .right : .left) : nil
        } else {
            turning = nil
        }
        // đã rẽ xong: tổng góc trong cửa sổ đủ lớn và giờ đã chạy thẳng lại
        guard turning == nil, let first = samples.first else { return nil }
        let total = heading - first.heading
        guard abs(total) >= minTurnDeg else { return nil }
        let dir: TurnDirection = abs(total) >= uturnDeg ? .uturn : (total > 0 ? .right : .left)
        let ev = TurnEvent(direction: dir, angleDeg: total, t: t)
        lastTurn = ev
        samples = [Sample(t: t, heading: heading)]
        return ev
    }

    /// a − b quấn về (−180, 180].
    public static func angleDiff(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}

/// Theo dõi ngã tư kế tiếp theo quãng đường đã đi; báo khi vừa đi qua.
public struct JunctionTracker: Equatable, Sendable {
    /// Đi quá vị trí ngã tư bấy nhiêu mét thì coi là đã qua.
    public var passMarginM: Double = 5
    /// Ngã tư cách ngã vừa qua dưới mức này coi là cùng một ngã tư (dữ liệu OSM lệch vài mét).
    public var sameJunctionM: Double = 15
    /// Vị trí (theo odometer) của ngã tư kế tiếp.
    public private(set) var targetAt: Double?
    public private(set) var lastPassedAt: Double?

    public init() {}

    public struct Update: Equatable, Sendable {
        public var nextM: Double?
        public var passed: Bool
    }

    /// `junctionsAhead`: khoảng cách (m) tới các ngã tư phía trước (OSM, có thể âm vài mét khi vừa qua);
    /// nil = không có dữ liệu, giữ dự đoán cũ.
    public mutating func update(odometer: Double, junctionsAhead: [Double]?) -> Update {
        var candidates: [Double] = []
        if let js = junctionsAhead {
            let lp = lastPassedAt, same = sameJunctionM
            candidates = js.map { odometer + $0 }.filter { pos in lp.map { abs(pos - $0) > same } ?? true }
            targetAt = candidates.min()
        }
        var passed = false
        if let ta = targetAt, odometer >= ta + passMarginM {
            passed = true
            lastPassedAt = ta
            let same = sameJunctionM
            targetAt = candidates.filter { abs($0 - ta) > same && $0 > ta }.min()
        }
        return Update(nextM: targetAt.map { $0 - odometer }, passed: passed)
    }

    /// Ngã tư được xác nhận bằng cách khác (xe vừa rẽ): coi như đã qua ngã tư gần nhất.
    public mutating func markPassed(odometer: Double) {
        lastPassedAt = targetAt.map { abs($0 - odometer) < 40 ? $0 : odometer } ?? odometer
        if let ta = targetAt, abs(ta - odometer) < 40 { targetAt = nil }
    }
}

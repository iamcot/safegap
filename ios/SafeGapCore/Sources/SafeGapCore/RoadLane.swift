// Mô hình làn ổn định trên mặt đường (mét) để vẽ màn lái: làn chỉ thẳng hoặc cong nhẹ, thay đổi chậm.
// Vạch nhận diện từng frame (LaneCurve trên ảnh) được chiếu xuống mặt đường, khớp parabol,
// kiểm tra có hợp lý không (bề rộng, góc lệch, độ cong, hai vạch song song) rồi mới trộn rất chậm vào mô hình.
// Mất vạch thì giữ nguyên một lúc, sau đó từ từ duỗi thẳng về giữa.
import Foundation

/// Làn mình: tâm làn x(z) = offset + heading·z + ½·curvature·z² (x sang phải, z phía trước, mét, gốc ở camera).
public struct RoadLane: Equatable, Sendable {
    public var offset: Double
    public var heading: Double
    public var curvature: Double
    public var width: Double
    /// true nếu vừa có vạch thật gần đây (vẽ đậm), false là đang giữ / mặc định (vẽ mờ).
    public var tracked: Bool

    public init(offset: Double = 0, heading: Double = 0, curvature: Double = 0, width: Double = 3.5, tracked: Bool = false) {
        self.offset = offset; self.heading = heading; self.curvature = curvature; self.width = width; self.tracked = tracked
    }

    public func center(_ z: Double) -> Double { offset + heading * z + 0.5 * curvature * z * z }
    public func left(_ z: Double) -> Double { center(z) - width / 2 }
    public func right(_ z: Double) -> Double { center(z) + width / 2 }
}

public struct RoadLaneConfig: Equatable, Sendable {
    /// Dải z dùng để khớp (gần quá thì vạch bị capo che, xa quá thì sai số lớn).
    public var zMin = 4.0
    public var zMax = 45.0
    public var minWidth = 2.6
    public var maxWidth = 4.6
    /// |dx/dz| tối đa (≈ 7°) và độ cong tối đa (bán kính ≥ 120 m) của làn đường bình thường.
    public var maxHeading = 0.12
    public var maxCurvature = 1.0 / 120.0
    /// Hai vạch phải gần song song.
    public var maxHeadingDiff = 0.06
    /// Hệ số trộn mỗi frame: nhỏ = mượt, chậm.
    public var alphaOffset = 0.12
    public var alphaHeading = 0.08
    public var alphaCurvature = 0.04
    public var alphaWidth = 0.03
    /// Mỗi frame tâm làn dịch tối đa bao nhiêu mét (chống nhảy).
    public var maxOffsetStep = 0.15
    /// Số frame giữ nguyên khi mất vạch, sau đó duỗi dần về thẳng giữa.
    public var holdFrames = 45
    public var relaxAlpha = 0.02

    public init() {}
}

public final class RoadLaneFilter {
    public let config: RoadLaneConfig
    public private(set) var lane = RoadLane()
    private var missed = Int.max / 2
    private var hasModel = false

    public init(config: RoadLaneConfig = RoadLaneConfig()) { self.config = config }

    public func reset() {
        lane = RoadLane()
        missed = Int.max / 2
        hasModel = false
    }

    /// Một vạch đã khớp: x(z) = a0 + a1·z + a2·z².
    public struct Fit: Equatable, Sendable {
        public var a0, a1, a2: Double
        public func x(_ z: Double) -> Double { a0 + a1 * z + a2 * z * z }
    }

    /// Khớp parabol (bình phương nhỏ nhất) cho điểm (x, z) trong dải tin được. nil nếu quá ít điểm.
    public func fit(_ pts: [(x: Double, z: Double)]) -> Fit? {
        let p = pts.filter { $0.z >= config.zMin && $0.z <= config.zMax && $0.x.isFinite }
        guard p.count >= 4, let zLo = p.map(\.z).min(), let zHi = p.map(\.z).max(), zHi - zLo > 6 else { return nil }
        // quy về z' = z - zRef cho ổn định số
        let zRef = (zLo + zHi) / 2
        var s = [Double](repeating: 0, count: 5), t = [Double](repeating: 0, count: 3)
        for q in p {
            let u = q.z - zRef
            var pw = 1.0
            for k in 0..<5 { s[k] += pw; if k < 3 { t[k] += pw * q.x }; pw *= u }
        }
        let m = [[s[0], s[1], s[2]], [s[1], s[2], s[3]], [s[2], s[3], s[4]]]
        guard let c = Self.solve3(m, t) else { return nil }
        // đổi về theo z: x = c0 + c1(z - r) + c2(z - r)²
        let a2 = c[2], a1 = c[1] - 2 * c[2] * zRef, a0 = c[0] - c[1] * zRef + c[2] * zRef * zRef
        return Fit(a0: a0, a1: a1, a2: a2)
    }

    static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let d = det(a)
        guard abs(d) > 1e-9 else { return nil }
        return (0..<3).map { i in
            var m = a
            for r in 0..<3 { m[r][i] = b[r] }
            return det(m) / d
        }
    }

    /// Một vạch có hợp lý không (nằm trong giới hạn của làn đường thường).
    func plausible(_ f: Fit) -> Bool {
        abs(f.a1) <= config.maxHeading && abs(2 * f.a2) <= config.maxCurvature && abs(f.a0) < 6
    }

    /// Cập nhật bằng điểm của vạch trái / phải (nil = không thấy). Trả về mô hình sau khi trộn.
    @discardableResult
    public func update(left: [(x: Double, z: Double)]?, right: [(x: Double, z: Double)]?) -> RoadLane {
        var fl = left.flatMap(fit), fr = right.flatMap(fit)
        if let f = fl, !plausible(f) { fl = nil }
        if let f = fr, !plausible(f) { fr = nil }
        if let a = fl, let b = fr {
            let w = b.x(10) - a.x(10)
            if w < config.minWidth || w > config.maxWidth || abs(a.a1 - b.a1) > config.maxHeadingDiff {
                // hai vạch mâu thuẫn: giữ vạch gần với mô hình hiện tại hơn
                if hasModel {
                    let el = abs(a.x(10) - lane.left(10)), er = abs(b.x(10) - lane.right(10))
                    if el <= er { fr = nil } else { fl = nil }
                } else {
                    fl = nil; fr = nil
                }
            }
        }

        // đo được: tâm làn, hướng, độ cong, bề rộng
        var meas: RoadLane?
        switch (fl, fr) {
        case let (a?, b?):
            meas = RoadLane(offset: (a.a0 + b.a0) / 2, heading: (a.a1 + b.a1) / 2, curvature: a.a2 + b.a2,
                            width: b.a0 - a.a0, tracked: true)
        case let (a?, nil):
            meas = RoadLane(offset: a.a0 + lane.width / 2, heading: a.a1, curvature: 2 * a.a2, width: lane.width, tracked: true)
        case let (nil, b?):
            meas = RoadLane(offset: b.a0 - lane.width / 2, heading: b.a1, curvature: 2 * b.a2, width: lane.width, tracked: true)
        default: break
        }

        if let m = meas {
            if !hasModel {
                lane = m
                lane.width = min(max(m.width, config.minWidth), config.maxWidth)
                hasModel = true
            } else {
                let c = config
                let dOff = c.alphaOffset * (m.offset - lane.offset)
                lane.offset += min(max(dOff, -c.maxOffsetStep), c.maxOffsetStep)
                lane.heading += c.alphaHeading * (m.heading - lane.heading)
                lane.curvature += c.alphaCurvature * (m.curvature - lane.curvature)
                lane.width += c.alphaWidth * (min(max(m.width, c.minWidth), c.maxWidth) - lane.width)
            }
            missed = 0
            lane.tracked = true
        } else {
            missed += 1
            if missed > config.holdFrames {
                // mất lâu: duỗi dần về làn thẳng, xe ở giữa
                let a = config.relaxAlpha
                lane.offset -= a * lane.offset
                lane.heading -= a * lane.heading
                lane.curvature -= a * lane.curvature
                lane.width += a * (3.5 - lane.width)
                lane.tracked = false
            }
        }
        return lane
    }
}

// Kalman 1D (D, dD/dt) + tracking bằng IoU (port từ proto/tracker.py, mục 3.5).
import Foundation

/// Mô hình vận tốc không đổi. Nhiễu đo tỉ lệ với D (xa thì kém chính xác hơn).
public struct Kalman1D: Equatable, Sendable {
    public private(set) var x0: Double  // D
    public private(set) var x1: Double  // dD/dt
    // P = [[p00, p01], [p10, p11]]
    public private(set) var p00, p01, p10, p11: Double
    public let accelSigma: Double
    public let measRelSigma: Double

    public init(d0: Double, accelSigma: Double = 3.0, measRelSigma: Double = 0.08) {
        x0 = d0
        x1 = 0
        let r = measRelSigma * d0
        p00 = r * r; p01 = 0; p10 = 0; p11 = 25.0
        self.accelSigma = accelSigma
        self.measRelSigma = measRelSigma
    }

    public var distance: Double { x0 }
    /// dD/dt (m/s). Âm = đang lại gần.
    public var rate: Double { x1 }

    public mutating func predict(dt: Double) {
        let q = accelSigma * accelSigma
        let q00 = q * (pow(dt, 4) / 4), q01 = q * (pow(dt, 3) / 2), q11 = q * (dt * dt)
        // x = F x, F = [[1, dt], [0, 1]]
        x0 = x0 + dt * x1
        // P = F P F^T + Q
        let a00 = p00 + dt * p10, a01 = p01 + dt * p11
        let a10 = p10, a11 = p11
        p00 = a00 + a01 * dt + q00
        p01 = a01 + q01
        p10 = a10 + a11 * dt + q01
        p11 = a11 + q11
    }

    public mutating func update(z: Double) {
        let r = measRelSigma * max(z, 1.0)
        let s = p00 + r * r
        let k0 = p00 / s, k1 = p10 / s
        let innov = z - x0
        x0 += k0 * innov
        x1 += k1 * innov
        let n00 = (1 - k0) * p00, n01 = (1 - k0) * p01
        let n10 = -k1 * p00 + p10, n11 = -k1 * p01 + p11
        p00 = n00; p01 = n01; p10 = n10; p11 = n11
    }
}

public func iou(_ a: Box, _ b: Box) -> Double {
    let ix1 = max(a.x1, b.x1), iy1 = max(a.y1, b.y1)
    let ix2 = min(a.x2, b.x2), iy2 = min(a.y2, b.y2)
    let inter = max(0.0, ix2 - ix1) * max(0.0, iy2 - iy1)
    if inter == 0 { return 0 }
    let areaA = (a.x2 - a.x1) * (a.y2 - a.y1)
    let areaB = (b.x2 - b.x1) * (b.y2 - b.y1)
    return inter / (areaA + areaB - inter)
}

public struct Track: Equatable, Sendable {
    public let id: Int
    public var box: Box
    public var cls: String
    public var kf: Kalman1D?
    public var missed: Int = 0
    public var hits: Int = 1
}

/// Ghép box giữa các frame theo IoU (tham lam). Mỗi track giữ 1 Kalman cho D.
public final class IoUTracker {
    public let iouMatch: Double
    public let maxMissed: Int
    public let accelSigma: Double
    public let measRelSigma: Double
    public private(set) var tracks: [Int: Track] = [:]
    private var nextId = 1

    public init(iouMatch: Double = 0.3, maxMissed: Int = 10, accelSigma: Double = 3.0, measRelSigma: Double = 0.08) {
        self.iouMatch = iouMatch
        self.maxMissed = maxMissed
        self.accelSigma = accelSigma
        self.measRelSigma = measRelSigma
    }

    public convenience init(_ c: TrackerConfig) {
        self.init(iouMatch: c.iouMatch, maxMissed: c.maxMissed, accelSigma: c.accelSigma, measRelSigma: c.measRelSigma)
    }

    /// Trả về track id cho từng box (cùng thứ tự).
    @discardableResult
    public func update(boxes: [Box], classes: [String]) -> [Int] {
        // id tăng dần nên duyệt theo id = thứ tự thêm vào (giống dict của Python)
        let ids = tracks.keys.sorted()
        var pairs: [(s: Double, tid: Int, i: Int)] = []
        for tid in ids {
            let t = tracks[tid]!
            for (i, b) in boxes.enumerated() {
                let s = iou(t.box, b)
                if s >= iouMatch { pairs.append((s, tid, i)) }
            }
        }
        // giống pairs.sort(reverse=True) của Python: so (s, tid, i) giảm dần
        pairs.sort { l, r in
            if l.s != r.s { return l.s > r.s }
            if l.tid != r.tid { return l.tid > r.tid }
            return l.i > r.i
        }
        var usedT = Set<Int>()
        var assigned = [Int?](repeating: nil, count: boxes.count)
        for p in pairs {
            if usedT.contains(p.tid) || assigned[p.i] != nil { continue }
            usedT.insert(p.tid)
            assigned[p.i] = p.tid
            tracks[p.tid]!.box = boxes[p.i]
            tracks[p.tid]!.cls = classes[p.i]
            tracks[p.tid]!.missed = 0
            tracks[p.tid]!.hits += 1
        }
        for tid in ids where !usedT.contains(tid) {
            tracks[tid]!.missed += 1
            if tracks[tid]!.missed > maxMissed { tracks[tid] = nil }
        }
        for (i, b) in boxes.enumerated() where assigned[i] == nil {
            let tid = nextId
            nextId += 1
            tracks[tid] = Track(id: tid, box: b, cls: classes[i])
            assigned[i] = tid
        }
        return assigned.map { $0! }
    }

    /// Frame không thấy xe: chỉ dự đoán D của track tid theo Kalman (vận tốc tương đối giữ nguyên). nil nếu track chưa có D.
    public func coastDistance(tid: Int, dt: Double) -> Double? {
        guard var t = tracks[tid], var kf = t.kf else { return nil }
        kf.predict(dt: dt)
        t.kf = kf
        tracks[tid] = t
        return kf.distance
    }

    /// Lọc D đo được của track tid, trả về D đã làm mượt.
    public func updateDistance(tid: Int, dMeas: Double, dt: Double) -> Double {
        guard var t = tracks[tid] else { return dMeas }
        if var kf = t.kf {
            kf.predict(dt: dt)
            kf.update(z: dMeas)
            t.kf = kf
        } else {
            t.kf = Kalman1D(d0: dMeas, accelSigma: accelSigma, measRelSigma: measRelSigma)
        }
        tracks[tid] = t
        return t.kf!.distance
    }
}

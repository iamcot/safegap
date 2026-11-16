// Nhận diện vạch làn đơn giản (Phase 3): tìm vệt sáng hẹp trên từng hàng ảnh xám, khớp đường cong bậc 2
// cho vạch trái / phải của làn mình, rồi dựng ROI bám theo làn thay cho hình thang cố định.
// Toạ độ chuẩn hoá 0..1 (x theo chiều rộng, y theo chiều cao, y từ trên xuống).
import Foundation

/// Ảnh xám 8 bit, hàng nối tiếp nhau (đã thu nhỏ, ví dụ 320×180).
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height))
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }
}

/// x = c0 + c1*(y - yRef) + c2*(y - yRef)^2 (chuẩn hoá). Đường thẳng khi c2 = 0.
public struct LaneCurve: Equatable, Sendable {
    public var c0, c1, c2: Double
    public var yRef: Double

    public init(c0: Double, c1: Double, c2: Double = 0, yRef: Double = 1.0) {
        self.c0 = c0; self.c1 = c1; self.c2 = c2; self.yRef = yRef
    }

    public func x(at y: Double) -> Double {
        let u = y - yRef
        return c0 + c1 * u + c2 * u * u
    }

    /// Trộn với đường cũ (làm mượt theo thời gian). a = trọng số của đường mới.
    public func blended(toward new: LaneCurve, a: Double) -> LaneCurve {
        precondition(yRef == new.yRef)
        return LaneCurve(c0: c0 + a * (new.c0 - c0), c1: c1 + a * (new.c1 - c1), c2: c2 + a * (new.c2 - c2), yRef: yRef)
    }
}

public struct LaneConfig: Equatable, Sendable {
    /// Dải hàng tìm vạch (chuẩn hoá). App đặt yTop theo đỉnh ROI, yBottom ngay trên capo.
    public var yTop = 0.55
    public var yBottom = 0.92
    public var rows = 36
    /// Nửa cửa sổ so sáng (pixel ảnh thu nhỏ) và độ sáng hơn nền tối thiểu.
    public var window = 12
    public var minContrast = 28
    /// Bề rộng tối đa một vệt vạch (tỉ lệ chiều rộng ảnh).
    public var maxMarkWidth = 0.05
    public var minPoints = 8
    /// Sai lệch tối đa của điểm so với đường khớp (tỉ lệ chiều rộng).
    public var maxResidual = 0.02
    /// Bề rộng làn hợp lệ ở đáy dải tìm (tỉ lệ chiều rộng ảnh).
    public var minLaneWidth = 0.15
    public var maxLaneWidth = 1.2

    public init() {}
}

public struct LaneDetection: Equatable, Sendable {
    public var left: LaneCurve?
    public var right: LaneCurve?
    public var leftPoints: Int
    public var rightPoints: Int
}

public enum LaneDetector {
    /// center(y): tâm làn mình dự đoán (từ lần trước hoặc ROI hiệu chỉnh), để chia vạch trái / phải
    /// và chọn vạch gần tâm nhất mỗi bên (bỏ vạch của làn bên cạnh).
    /// gate(y): khi đã có làn ổn định, vị trí dự đoán của vạch trái / phải ở hàng y và sai lệch cho phép.
    /// Có gate thì mỗi hàng chỉ nhận vệt gần vị trí dự đoán nhất, nằm trong sai lệch; vệt khác (xe, đèn, vạch làn khác) bỏ qua.
    public static func detect(_ img: GrayImage, config c: LaneConfig = .init(), center: (Double) -> Double,
                              gate: ((Double) -> (left: Double, right: Double, tol: Double))? = nil) -> LaneDetection {
        let W = img.width, H = img.height
        var leftPts: [(y: Double, x: Double)] = []
        var rightPts: [(y: Double, x: Double)] = []
        let w = max(2, c.window)
        let maxRun = max(2, Int(c.maxMarkWidth * Double(W)))
        var prefix = [Int](repeating: 0, count: W + 1)

        for r in 0..<c.rows {
            let yn = c.yTop + (c.yBottom - c.yTop) * Double(r) / Double(max(1, c.rows - 1))
            let py = min(H - 1, max(0, Int(yn * Double(H))))
            let base = py * W
            for x in 0..<W { prefix[x + 1] = prefix[x] + Int(img.pixels[base + x]) }
            func mean(_ a: Int, _ b: Int) -> Double {  // [a, b)
                let lo = max(0, a), hi = min(W, b)
                return hi > lo ? Double(prefix[hi] - prefix[lo]) / Double(hi - lo) : 255
            }
            // vệt sáng hẹp: sáng hơn cả nền bên trái lẫn bên phải
            var runs: [(start: Int, end: Int)] = []
            var start = -1
            for x in w..<(W - w) {
                let v = Double(img.pixels[base + x])
                let bg = max(mean(x - w, x - w / 2), mean(x + w / 2 + 1, x + w + 1))
                let on = v - bg >= Double(c.minContrast)
                if on, start < 0 { start = x }
                if !on, start >= 0 { runs.append((start, x)); start = -1 }
            }
            if start >= 0 { runs.append((start, W - w)) }

            if let g = gate?(yn) {
                let xs = runs.filter { $0.end - $0.start <= maxRun }
                    .map { (Double($0.start + $0.end - 1) / 2.0 + 0.5) / Double(W) }
                if let l = xs.filter({ abs($0 - g.left) < g.tol }).min(by: { abs($0 - g.left) < abs($1 - g.left) }) {
                    leftPts.append((y: yn, x: l))
                }
                if let r = xs.filter({ abs($0 - g.right) < g.tol }).min(by: { abs($0 - g.right) < abs($1 - g.right) }) {
                    rightPts.append((y: yn, x: r))
                }
                continue
            }
            // giữ tối đa 3 vệt gần tâm nhất mỗi bên; chọn vạch của làn mình ở bước khớp đường
            let cx = center(yn)
            var ls: [Double] = [], rs: [Double] = []
            for run in runs where run.end - run.start <= maxRun {
                let xn = (Double(run.start + run.end - 1) / 2.0 + 0.5) / Double(W)
                if xn < cx { ls.append(xn) } else { rs.append(xn) }
            }
            ls.sort { cx - $0 < cx - $1 }
            rs.sort { $0 - cx < $1 - cx }
            leftPts += ls.prefix(3).map { (y: yn, x: $0) }
            rightPts += rs.prefix(3).map { (y: yn, x: $0) }
        }

        let cB = center(c.yBottom)
        var left = chooseLane(leftPts, centerAtBottom: cB, config: c)
        var right = chooseLane(rightPts, centerAtBottom: cB, config: c)
        // kiểm tra hình học: bề rộng làn hợp lý
        if let l = left, let r = right {
            let width = r.curve.x(at: c.yBottom) - l.curve.x(at: c.yBottom)
            if width < c.minLaneWidth || width > c.maxLaneWidth {
                if l.inliers >= r.inliers { right = nil } else { left = nil }
            }
        }
        return LaneDetection(left: left?.curve, right: right?.curve,
                             leftPoints: left?.inliers ?? 0, rightPoints: right?.inliers ?? 0)
    }

    /// Tách các đường thẳng bằng RANSAC (vét cạn cặp điểm, kết quả xác định), lấy đường gần tâm làn nhất
    /// có đủ điểm (vạch làn mình, kể cả vạch đứt), rồi khớp lại bậc 2 và gom thêm điểm theo đường cong.
    static func chooseLane(_ pts: [(y: Double, x: Double)], centerAtBottom cB: Double,
                           config c: LaneConfig) -> (curve: LaneCurve, inliers: Int)? {
        var rest = pts
        var best: (group: [(y: Double, x: Double)], dist: Double)?
        for _ in 0..<3 {
            guard let g = ransacLine(rest, tol: c.maxResidual, minPoints: c.minPoints) else { break }
            if let f = fit(g, yRef: c.yBottom, allowQuadratic: false) {
                let d = abs(f.x(at: c.yBottom) - cB)
                if best == nil || d < best!.dist { best = (g, d) }
            }
            let used = Set(g.map { "\($0.y),\($0.x)" })
            rest = rest.filter { !used.contains("\($0.y),\($0.x)") }
        }
        guard var group = best?.group else { return nil }
        var curve: LaneCurve?
        for _ in 0..<2 {
            guard let f = fit(group, yRef: c.yBottom) else { return nil }
            curve = f
            group = pts.filter { abs($0.x - f.x(at: $0.y)) < c.maxResidual }
            guard group.count >= c.minPoints else { return nil }
        }
        guard let final = fit(group, yRef: c.yBottom) ?? curve else { return nil }
        return (final, group.count)
    }

    static func ransacLine(_ pts: [(y: Double, x: Double)], tol: Double, minPoints: Int) -> [(y: Double, x: Double)]? {
        var bestCount = 0
        var bestLine: (y1: Double, x1: Double, a: Double)?
        let n = pts.count
        guard n >= minPoints else { return nil }
        for i in 0..<n {
            for j in (i + 1)..<n where abs(pts[j].y - pts[i].y) >= 0.05 {
                let a = (pts[j].x - pts[i].x) / (pts[j].y - pts[i].y)
                var cnt = 0
                for p in pts where abs(p.x - (pts[i].x + a * (p.y - pts[i].y))) < tol { cnt += 1 }
                if cnt > bestCount { bestCount = cnt; bestLine = (pts[i].y, pts[i].x, a) }
            }
        }
        guard let l = bestLine, bestCount >= minPoints else { return nil }
        return pts.filter { abs($0.x - (l.x1 + l.a * ($0.y - l.y1))) < tol }
    }

    static func fit(_ pts: [(y: Double, x: Double)], yRef: Double, allowQuadratic: Bool = true) -> LaneCurve? {
        let ys = pts.map(\.y)
        guard let lo = ys.min(), let hi = ys.max(), hi - lo > 0.05 else { return nil }
        let quadratic = allowQuadratic && hi - lo >= 0.2 && pts.count >= 10
        // tổng cho hệ phương trình chuẩn
        var s = [Double](repeating: 0, count: 5)   // Σu^k, k = 0..4
        var t = [Double](repeating: 0, count: 3)   // Σx·u^k, k = 0..2
        for p in pts {
            let u = p.y - yRef
            var uk = 1.0
            for k in 0..<5 {
                s[k] += uk
                if k < 3 { t[k] += p.x * uk }
                uk *= u
            }
        }
        if quadratic {
            let a = [[s[0], s[1], s[2]], [s[1], s[2], s[3]], [s[2], s[3], s[4]]]
            if let c = solve3(a, t) { return LaneCurve(c0: c[0], c1: c[1], c2: c[2], yRef: yRef) }
        }
        let det = s[0] * s[2] - s[1] * s[1]
        guard abs(det) > 1e-12 else { return nil }
        let c0 = (t[0] * s[2] - s[1] * t[1]) / det
        let c1 = (s[0] * t[1] - s[1] * t[0]) / det
        return LaneCurve(c0: c0, c1: c1, c2: 0, yRef: yRef)
    }

    static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        func det3(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
                - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let d = det3(a)
        guard abs(d) > 1e-14 else { return nil }
        return (0..<3).map { col in
            var m = a
            for r in 0..<3 { m[r][col] = b[r] }
            return det3(m) / d
        }
    }
}

/// Giữ vạch làn qua các frame: làm mượt, giữ thêm vài frame khi mất vạch (vạch đứt, xe che).
public struct LaneTracker: Sendable {
    public private(set) var left: LaneCurve?
    public private(set) var right: LaneCurve?
    private var missedL = 0, missedR = 0
    public var smoothing: Double
    public var maxMissed: Int

    public init(smoothing: Double = 0.35, maxMissed: Int = 15) {
        self.smoothing = smoothing; self.maxMissed = maxMissed
    }

    public mutating func update(_ d: LaneDetection) {
        (left, missedL) = Self.step(left, d.left, missedL, smoothing, maxMissed)
        (right, missedR) = Self.step(right, d.right, missedR, smoothing, maxMissed)
    }

    private static func step(_ old: LaneCurve?, _ new: LaneCurve?, _ missed: Int, _ a: Double, _ maxMissed: Int) -> (LaneCurve?, Int) {
        if let new {
            guard let old, old.yRef == new.yRef else { return (new, 0) }
            return (old.blended(toward: new, a: a), 0)
        }
        let m = missed + 1
        return m > maxMissed ? (nil, m) : (old, m)
    }

    public mutating func reset() { self = LaneTracker(smoothing: smoothing, maxMissed: maxMissed) }
}

public enum LaneROI {
    /// Bề rộng và tâm của hình thang ROI hiệu chỉnh ở độ cao y (ROI dạng [TL, TR, BR, BL]).
    static func trapezoid(_ roi: [Point], at y: Double) -> (left: Double, right: Double)? {
        guard roi.count == 4 else { return nil }
        let (tl, tr, br, bl) = (roi[0], roi[1], roi[2], roi[3])
        func lerp(_ a: Point, _ b: Point) -> Double {
            b.y == a.y ? a.x : a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y)
        }
        return (lerp(tl, bl), lerp(tr, br))
    }

    /// Tâm làn dự đoán ở độ cao y: theo vạch đang theo dõi, không có thì theo ROI hiệu chỉnh.
    public static func center(at y: Double, left: LaneCurve?, right: LaneCurve?, calibrated roi: [Point]) -> Double {
        let t = trapezoid(roi, at: y)
        switch (left, right) {
        case let (l?, r?): return (l.x(at: y) + r.x(at: y)) / 2
        case let (l?, nil): return l.x(at: y) + (t.map { ($0.right - $0.left) / 2 } ?? 0.15)
        case let (nil, r?): return r.x(at: y) - (t.map { ($0.right - $0.left) / 2 } ?? 0.15)
        default: return t.map { ($0.left + $0.right) / 2 } ?? 0.5
        }
    }

    /// ROI bám làn (chuẩn hoá) từ đỉnh ROI hiệu chỉnh tới đáy ảnh. Thiếu một vạch thì lấy bề rộng làn
    /// của ROI hiệu chỉnh. Không có vạch nào → nil (dùng ROI hiệu chỉnh).
    public static func polygon(left: LaneCurve?, right: LaneCurve?, calibrated roi: [Point], steps: Int = 8) -> [Point]? {
        guard left != nil || right != nil, let yTop = roi.map(\.y).min() else { return nil }
        let yBottom = 1.0
        var l: [Point] = [], r: [Point] = []
        for i in 0...steps {
            let y = yTop + (yBottom - yTop) * Double(i) / Double(steps)
            let half = trapezoid(roi, at: y).map { ($0.right - $0.left) / 2 } ?? 0.15
            let xl = left?.x(at: y) ?? (right!.x(at: y) - 2 * half)
            let xr = right?.x(at: y) ?? (left!.x(at: y) + 2 * half)
            guard xr > xl else { return nil }
            l.append(Point(xl, y))
            r.append(Point(xr, y))
        }
        return l + r.reversed()
    }
}

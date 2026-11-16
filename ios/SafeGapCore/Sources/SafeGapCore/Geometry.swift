// Kiểu dữ liệu chung + chọn xe cùng làn (port từ proto/lane.py, mục 3.2).
import Foundation

public struct Point: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    // JSON dạng [x, y] giống config/default.json
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
    }
}

/// Box (x1, y1, x2, y2) theo pixel, gốc trên-trái, y tính từ trên xuống.
public struct Box: Equatable, Sendable {
    public var x1, y1, x2, y2: Double
    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }
}

public struct Detection: Equatable, Sendable {
    public var x1, y1, x2, y2: Double
    public var cls: String
    public var conf: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ cls: String, _ conf: Double = 1.0) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2; self.cls = cls; self.conf = conf
    }

    public var width: Double { x2 - x1 }
    public var bottomCenter: Point { Point((x1 + x2) / 2.0, y2) }
    public var box: Box { Box(x1, y1, x2, y2) }
}

public enum Lane {
    /// Ray casting.
    public static func pointInPolygon(_ x: Double, _ y: Double, _ poly: [Point]) -> Bool {
        var inside = false
        let n = poly.count
        guard n > 0 else { return false }
        var j = n - 1
        for i in 0..<n {
            let (xi, yi) = (poly[i].x, poly[i].y)
            let (xj, yj) = (poly[j].x, poly[j].y)
            if (yi > y) != (yj > y) {
                let xCross = xi + (y - yi) * (xj - xi) / (yj - yi)
                if x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    public static func roiToPixels(_ polyNorm: [Point], width: Double, height: Double) -> [Point] {
        polyNorm.map { Point($0.x * width, $0.y * height) }
    }

    /// Chỉ số của xe có tâm đáy trong ROI và gần nhất (y2 lớn nhất). Bằng nhau thì giữ xe đứng trước.
    public static func selectEgo(_ dets: [Detection], roi: [Point]) -> Int? {
        guard let yMax = roi.map(\.y).max() else { return nil }
        var best: Int?
        for (i, d) in dets.enumerated() {
            let c = d.bottomCenter
            let cy = min(c.y, yMax - 1e-6)  // xe sát mép dưới khung hình vẫn tính là trong ROI
            if pointInPolygon(c.x, cy, roi), best == nil || d.y2 > dets[best!].y2 {
                best = i
            }
        }
        return best
    }
}

/// Bỏ box của chính xe mình (capo, taplo): YOLO hay nhận nhầm là "car", box rộng gần hết khung / chạm đáy ảnh.
/// Giống điều kiện lọc trong proto/pipeline.py.
public struct OwnVehicleFilter: Equatable, Sendable {
    public var maxWidthPx: Double
    public var maxBottomPx: Double

    public init(maxWidthRatio: Double, maxBottomRatio: Double, frameWidth: Double, frameHeight: Double) {
        maxWidthPx = maxWidthRatio * frameWidth
        maxBottomPx = maxBottomRatio * frameHeight
    }

    public func keeps(_ d: Detection) -> Bool {
        d.width > 0 && d.width <= maxWidthPx && d.y2 <= maxBottomPx
    }
}

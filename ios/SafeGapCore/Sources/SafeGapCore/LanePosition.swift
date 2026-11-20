// Xe đang ở làn thứ mấy (chủ app 20/11): đếm xe cùng chiều ở làn bên trái / bên phải + số làn OSM, thay vì chỉ dựa
// vào GPS (GPS lệch 3–10 m, hơn cả một làn).
// - thấy xe cùng chiều cả hai bên: làn giữa (đường 3 làn), hoặc làn thứ (số làn có xe bên trái) tính từ trái;
// - chỉ thấy xe bên phải: làn ngoài cùng bên trái; chỉ thấy xe bên trái: làn ngoài cùng bên phải;
// - thấy xe ngược chiều cách n làn (đường hai chiều): làn thứ n tính từ vạch giữa;
// - không thấy xe nào: GPS (nếu có), không thì coi là sát vạch giữa / mép trái.
// Nhớ xe hai bên trong `memoryS` giây; xe đổi làn (RoadLaneFilter.laneChange) thì dời số đã nhớ theo.
import Foundation

public struct LanePosition: Equatable, Sendable {
    public enum Source: String, Sendable { case vehicles, oncoming, gps, none }
    /// Làn của xe mình, 0 = làn ngoài cùng bên trái (sát vạch giữa với đường hai chiều).
    public var fromLeft: Int
    /// Số làn cùng chiều (OSM, hoặc nhiều hơn nếu camera thấy xe ở nhiều làn hơn).
    public var lanes: Int
    public var source: Source
    /// 0 = làn ngoài cùng bên phải (sát lề).
    public var fromRight: Int { lanes - 1 - fromLeft }

    public init(fromLeft: Int, lanes: Int, source: Source) {
        self.fromLeft = fromLeft; self.lanes = lanes; self.source = source
    }
}

public struct LanePositionEstimator: Sendable {
    /// Nhớ đã thấy xe ở làn bên trái / phải trong bấy nhiêu giây (xe hai bên không lúc nào cũng có trong hình).
    public var memoryS = 6.0
    /// Số làn có xe đã thấy ở mỗi bên (1 = làn ngay cạnh) và lúc thấy.
    private var left: (n: Int, t: Double)?
    private var right: (n: Int, t: Double)?

    public init() {}

    public mutating func reset() { left = nil; right = nil }

    /// Xe mình vừa đổi làn: −1 sang trái, +1 sang phải. Xe đã thấy hai bên dời theo.
    public mutating func laneChanged(_ dir: Int) {
        guard dir != 0 else { return }
        func move(_ s: (n: Int, t: Double)?, by d: Int) -> (n: Int, t: Double)? {
            guard let s else { return nil }
            return s.n + d > 0 ? (s.n + d, s.t) : nil
        }
        left = move(left, by: dir)      // sang phải: xe bên trái xa thêm một làn
        right = move(right, by: -dir)
    }

    /// `laneOffsets`: làn của từng xe cùng chiều so với làn mình (−1 = làn ngay bên trái, +1 = ngay bên phải; 0 bỏ).
    /// `oncomingLanesLeft`: xe ngược chiều gần nhất cách bao nhiêu làn về bên trái (1 = ngay làn bên kia vạch giữa).
    /// `gpsFromRight`: GPS + OSM đoán xe cách mép phải bao nhiêu làn (0 = làn sát lề), chỉ dùng khi camera không có gì.
    public mutating func update(t: Double, laneOffsets: [Int], oncomingLanesLeft: Int? = nil, lanesSame: Int?,
                                gpsFromRight: Int? = nil) -> LanePosition {
        if let l = left, t - l.t > memoryS { left = nil }
        if let r = right, t - r.t > memoryS { right = nil }
        if let m = laneOffsets.filter({ $0 < 0 }).min() {
            let n = -m
            left = (max(n, left?.n ?? 0), t)
        }
        if let m = laneOffsets.filter({ $0 > 0 }).max() {
            right = (max(m, right?.n ?? 0), t)
        }
        let l = left?.n ?? 0, r = right?.n ?? 0
        // OSM sai / thiếu số làn: camera thấy xe ở nhiều làn hơn thì tin camera
        let lanes = max(lanesSame ?? 1, l + r + 1, 1)
        if let n = oncomingLanesLeft, n >= 1 {
            return LanePosition(fromLeft: min(n - 1, lanes - 1), lanes: lanes, source: .oncoming)
        }
        if l > 0 && r > 0 { return LanePosition(fromLeft: min(l, lanes - 1 - r), lanes: lanes, source: .vehicles) }
        if r > 0 { return LanePosition(fromLeft: 0, lanes: lanes, source: .vehicles) }
        if l > 0 { return LanePosition(fromLeft: lanes - 1, lanes: lanes, source: .vehicles) }
        if let g = gpsFromRight {
            return LanePosition(fromLeft: min(max(lanes - 1 - g, 0), lanes - 1), lanes: lanes, source: .gps)
        }
        return LanePosition(fromLeft: 0, lanes: lanes, source: .none)
    }
}

// Xe đang ở làn thứ mấy (chủ app 20/11): đếm xe cùng chiều ở làn bên trái / bên phải + số làn OSM, thay vì chỉ dựa
// vào GPS (GPS lệch 3–10 m, hơn cả một làn).
// - thấy xe cùng chiều cả hai bên: làn giữa (đường 3 làn), hoặc làn thứ (số làn có xe bên trái) tính từ trái;
// - chỉ thấy xe bên phải: làn ngoài cùng bên trái; chỉ thấy xe bên trái: làn ngoài cùng bên phải;
// - thấy xe ngược chiều cách n làn (đường hai chiều): làn thứ n tính từ vạch giữa;
// - không thấy xe nào: GPS (nếu có), không thì coi là sát vạch giữa / mép trái.
// Nhớ xe hai bên trong `memoryS` giây (mỗi làn phải thấy ≥ `minHits` frame mới tính, số làn không vượt OSM + 1); xe đổi làn (RoadLaneFilter.laneChange) thì dời số đã nhớ theo.
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
    /// Một làn bên cạnh phải thấy xe ít nhất ngần này frame (trong `memoryS`) mới tính: bỏ nhiễu một hai frame
    /// (xe đỗ lề, xe đi chéo, box sai). Log 20/11 tối: không lọc thì đường 3 làn thành 7–10 làn.
    public var minHits = 3
    /// Camera thấy nhiều làn hơn OSM thì chỉ tin thêm tối đa ngần này làn (OSM thiếu / sai), không có OSM thì tối đa 4.
    public var maxExtraLanes = 1
    public var maxLanesNoMap = 4

    /// Theo từng độ lệch làn k (−2…−1, 1…2): số frame đã thấy xe và lúc thấy gần nhất.
    private var seen: [Int: (hits: Int, t: Double)] = [:]

    public init() {}

    public mutating func reset() { seen = [:] }

    /// Xe mình vừa đổi làn: −1 sang trái, +1 sang phải. Xe đã thấy hai bên dời theo.
    public mutating func laneChanged(_ dir: Int) {
        guard dir != 0 else { return }
        var moved: [Int: (hits: Int, t: Double)] = [:]
        for (k, v) in seen {
            let nk = k - dir
            if nk != 0 { moved[nk] = v }
        }
        seen = moved
    }

    /// `laneOffsets`: làn của từng xe cùng chiều so với làn mình (−1 = làn ngay bên trái, +1 = ngay bên phải; 0 bỏ).
    /// `oncomingLanesLeft`: xe ngược chiều gần nhất cách bao nhiêu làn về bên trái (1 = ngay làn bên kia vạch giữa).
    /// `gpsFromRight`: GPS + OSM đoán xe cách mép phải bao nhiêu làn (0 = làn sát lề), chỉ dùng khi camera không có gì.
    public mutating func update(t: Double, laneOffsets: [Int], oncomingLanesLeft: Int? = nil, lanesSame: Int?,
                                gpsFromRight: Int? = nil) -> LanePosition {
        seen = seen.filter { t - $0.value.t <= memoryS }
        for k in Set(laneOffsets) where k != 0 && abs(k) <= 2 {
            seen[k] = ((seen[k]?.hits ?? 0) + 1, t)
        }
        let sure = seen.filter { $0.value.hits >= minHits }.keys
        var l = -(sure.filter { $0 < 0 }.min() ?? 0)
        var r = sure.filter { $0 > 0 }.max() ?? 0
        let cap = lanesSame.map { max($0, 1) + maxExtraLanes } ?? maxLanesNoMap
        let lanes = min(max(lanesSame ?? 1, l + r + 1, 1), cap)
        l = min(l, lanes - 1); r = min(r, lanes - 1)
        if let n = oncomingLanesLeft, n >= 1 {
            return LanePosition(fromLeft: min(n - 1, lanes - 1), lanes: lanes, source: .oncoming)
        }
        if l > 0 && r > 0 { return LanePosition(fromLeft: max(min(l, lanes - 1 - r), 0), lanes: lanes, source: .vehicles) }
        if r > 0 { return LanePosition(fromLeft: 0, lanes: lanes, source: .vehicles) }
        if l > 0 { return LanePosition(fromLeft: lanes - 1, lanes: lanes, source: .vehicles) }
        if let g = gpsFromRight {
            return LanePosition(fromLeft: min(max(lanes - 1 - g, 0), lanes - 1), lanes: lanes, source: .gps)
        }
        return LanePosition(fromLeft: 0, lanes: lanes, source: .none)
    }
}

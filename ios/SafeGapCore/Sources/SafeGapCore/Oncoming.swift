// Nhận xe đi ngược chiều. YOLO không phân biệt đầu/đuôi xe, nên dựa vào hai dấu hiệu theo từng track:
//  1. tốc độ tiến lại (khoảng cách giảm) lớn hơn hẳn tốc độ xe mình: xe cùng chiều không thể lại gần nhanh hơn ta chạy;
//  2. nằm bên trái làn mình (Việt Nam đi bên phải).
// Khoảng cách theo bề rộng box nhiễu nhiều, nên tốc độ tiến lại tính bằng hồi quy tuyến tính trên ~1 giây gần nhất,
// và cần vài lần bỏ phiếu liên tiếp mới kết luận (có trễ khi bỏ).
import Foundation

public struct OncomingConfig: Equatable, Sendable {
    /// Tiến lại nhanh hơn tốc độ xe mình ít nhất bao nhiêu m/s (≈ 15 km/h).
    public var marginMps = 4.0
    /// Khi không có tốc độ xe mình (chưa có GPS): ngưỡng tốc độ tiến lại tuyệt đối.
    public var minClosingNoSpeedMps = 7.0
    /// Phải lệch trái khỏi mép trái làn mình ít nhất bao nhiêu mét.
    public var leftMarginM = 0.3
    /// Cửa sổ hồi quy (giây) và thời gian tối thiểu có dữ liệu.
    public var windowS = 1.0
    public var minSpanS = 0.4
    /// Số phiếu để bật / tối đa.
    public var votesOn = 3
    public var votesMax = 6
    /// Bỏ track không thấy quá lâu.
    public var forgetS = 2.0

    public init() {}
}

public final class OncomingClassifier {
    public struct Observation: Sendable {
        public var id: Int
        /// Khoảng cách (m) và độ lệch ngang so với tâm làn mình (m, âm = bên trái).
        public var distance: Double
        public var lateral: Double
        public init(id: Int, distance: Double, lateral: Double) {
            self.id = id; self.distance = distance; self.lateral = lateral
        }
    }

    struct State {
        var samples: [(t: Double, d: Double)] = []
        var votes = 0
        var oncoming = false
        var lastSeen = 0.0
    }

    public let config: OncomingConfig
    private var states: [Int: State] = [:]

    public init(config: OncomingConfig = OncomingConfig()) { self.config = config }

    public func reset() { states.removeAll() }

    /// Tốc độ tiến lại (m/s, dương = đang lại gần) của track, nil nếu chưa đủ dữ liệu.
    public func closingSpeed(_ id: Int) -> Double? {
        guard let s = states[id]?.samples, s.count >= 4, let t0 = s.first?.t, let t1 = s.last?.t,
              t1 - t0 >= config.minSpanS else { return nil }
        let n = Double(s.count)
        let mt = s.map(\.t).reduce(0, +) / n, md = s.map(\.d).reduce(0, +) / n
        var num = 0.0, den = 0.0
        for q in s { num += (q.t - mt) * (q.d - md); den += (q.t - mt) * (q.t - mt) }
        guard den > 0 else { return nil }
        return -num / den
    }

    /// Cập nhật một frame. Trả về tập id track đang được coi là xe ngược chiều.
    @discardableResult
    public func update(t: Double, ownSpeedMps: Double?, laneHalfWidth: Double, observations: [Observation]) -> Set<Int> {
        let c = config
        for o in observations where o.distance.isFinite && o.distance > 0 {
            var s = states[o.id] ?? State()
            s.samples.append((t, o.distance))
            s.samples.removeAll { t - $0.t > c.windowS }
            s.lastSeen = t
            states[o.id] = s
            guard let closing = closingSpeed(o.id) else { continue }
            let threshold = ownSpeedMps.map { $0 + c.marginMps } ?? c.minClosingNoSpeedMps
            let onLeft = o.lateral < -(laneHalfWidth + c.leftMarginM)
            var st = states[o.id]!
            if closing > threshold && onLeft {
                st.votes = min(st.votes + 1, c.votesMax)
            } else {
                st.votes = max(st.votes - 1, 0)
            }
            if st.votes >= c.votesOn { st.oncoming = true }
            if st.votes == 0 { st.oncoming = false }
            states[o.id] = st
        }
        states = states.filter { t - $0.value.lastSeen <= c.forgetS }
        return Set(states.filter { $0.value.oncoming }.map(\.key))
    }
}

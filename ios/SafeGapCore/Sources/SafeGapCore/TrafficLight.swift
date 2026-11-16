// Đèn giao thông bản thô (docs/DRIVER_ASSIST.md, A4): khung đèn từ lớp "traffic light" của YOLO COCO,
// màu theo HSV của các điểm sáng trong khung, chọn đèn liên quan, bỏ phiếu qua nhiều frame, giữ trạng thái khi mất đèn.
// Giai đoạn C thay phần màu bằng classifier (mũi tên, đồng hồ đếm ngược).
import Foundation

public enum LightColor: String, Codable, Sendable, CaseIterable {
    case red, yellow, green, unknown

    public var label: String {
        switch self {
        case .red: return "ĐỎ"
        case .yellow: return "VÀNG"
        case .green: return "XANH"
        case .unknown: return "?"
        }
    }
}

public enum LightColorClassifier {
    /// Phân loại từ các điểm ảnh RGB (0..255) lấy mẫu trong khung đèn.
    /// Chỉ đếm điểm sáng và đậm màu (bóng đèn đang bật); vỏ đèn đen và nền trời bị loại.
    public static func classify(_ pixels: [(r: Double, g: Double, b: Double)],
                                minValue: Double = 0.55, minSaturation: Double = 0.45,
                                minFraction: Double = 0.02, minCount: Int = 3) -> LightColor {
        var counts: [LightColor: Int] = [:]
        for p in pixels {
            let (h, s, v) = hsv(p.r, p.g, p.b)
            guard v >= minValue, s >= minSaturation else { continue }
            let c: LightColor
            switch h {
            // đèn đỏ LED qua camera hay ngả cam (hue 15–25): vẫn tính đỏ
            case ..<26, 330...: c = .red
            case 26..<72: c = .yellow
            case 75..<210: c = .green   // đèn xanh LED ở VN ngả xanh lơ
            default: continue
            }
            counts[c, default: 0] += 1
        }
        guard let best = counts.max(by: { $0.value < $1.value }) else { return .unknown }
        let need = max(minCount, Int((Double(pixels.count) * minFraction).rounded(.up)))
        return best.value >= need ? best.key : .unknown
    }

    /// Như `classify` nhưng có vị trí điểm trong khung (u ngang, v dọc, 0..1) và tỉ lệ khung (cao / rộng).
    /// Đèn dọc: đỏ trên, vàng giữa, xanh dưới; đèn ngang: đỏ trái, vàng giữa, xanh phải.
    /// Màu theo hue lưỡng lự giữa đỏ/vàng/xanh thì vị trí bóng đang sáng quyết định.
    public static func classify(_ pixels: [(r: Double, g: Double, b: Double, u: Double, v: Double)], aspect: Double,
                                minValue: Double = 0.55, minSaturation: Double = 0.45) -> LightColor {
        let hueColor = classify(pixels.map { (r: $0.r, g: $0.g, b: $0.b) }, minValue: minValue, minSaturation: minSaturation)
        guard hueColor != .unknown else { return .unknown }
        let vertical = aspect >= 1.5, horizontal = aspect <= 1 / 1.5
        guard vertical || horizontal else { return hueColor }
        var sum = 0.0, n = 0.0
        for p in pixels {
            let (_, sat, val) = hsv(p.r, p.g, p.b)
            guard val >= minValue, sat >= minSaturation else { continue }
            sum += vertical ? p.v : p.u
            n += 1
        }
        guard n > 0 else { return hueColor }
        let pos = sum / n
        let byPos: LightColor = pos < 0.36 ? .red : (pos > 0.64 ? .green : .yellow)
        // hue rõ ràng xanh/đỏ mà vị trí là giữa: tin hue (đèn 2 bóng, khung lệch); vàng thì phải khớp vị trí
        if hueColor == .yellow { return byPos }
        if byPos == .yellow { return hueColor }
        return byPos == hueColor ? hueColor : byPos
    }

    /// h độ (0..360), s, v (0..1).
    public static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let r = r / 255, g = g / 255, b = b / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r {
                h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6)
            } else if mx == g {
                h = 60 * ((b - r) / d + 2)
            } else {
                h = 60 * ((r - g) / d + 4)
            }
        }
        if h < 0 { h += 360 }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    /// YCbCr full range (BT.601) → RGB, như buffer 420f của camera.
    public static func rgb(y: Double, cb: Double, cr: Double) -> (r: Double, g: Double, b: Double) {
        func clamp(_ x: Double) -> Double { min(255, max(0, x)) }
        return (clamp(y + 1.402 * (cr - 128)),
                clamp(y - 0.344136 * (cb - 128) - 0.714136 * (cr - 128)),
                clamp(y + 1.772 * (cb - 128)))
    }
}

public struct TrafficLightState: Equatable, Sendable {
    public var color: LightColor
    /// Lúc màu hiện tại bắt đầu (s, thời gian frame).
    public var since: Double
    /// Lần cuối còn thấy đèn trong khung.
    public var lastSeen: Double
    /// Khung đèn liên quan (pixel), nil khi đang giữ trạng thái vì mất đèn.
    public var box: Box?
    /// Chiều cao khung (pixel) lần cuối thấy: đèn càng to càng gần.
    public var heightPx: Double

    public init(color: LightColor, since: Double, lastSeen: Double, box: Box?, heightPx: Double) {
        self.color = color
        self.since = since
        self.lastSeen = lastSeen
        self.box = box
        self.heightPx = heightPx
    }
}

/// Chọn đèn áp dụng cho xe mình và làm mượt màu qua nhiều frame.
public struct TrafficLightTracker: Equatable, Sendable {
    /// Số lần quan sát gần nhất dùng để bỏ phiếu.
    public var votes = 5
    /// Mất đèn bao lâu (s) thì bỏ trạng thái khi xe đứng / nhích (đèn ra khỏi khung lúc dừng sát vạch).
    public var holdS = 8.0
    /// Khi xe đang chạy (≥ `movingKmh`) mất đèn thì bỏ sớm: đã đi qua đèn, chui hầm, rẽ.
    public var holdMovingS = 2.0
    public var movingKmh = 10.0
    /// Đèn nhỏ hơn (pixel chiều cao) thì bỏ qua (quá xa, dễ nhầm đèn xe).
    public var minHeightPx = 14.0

    private var history: [LightColor] = []
    public private(set) var state: TrafficLightState?

    public init() {}

    /// Điểm chọn đèn: to (gần), nằm gần giữa theo chiều ngang, phía trên ảnh. Cao hơn = ưu tiên.
    public static func score(_ d: Detection, frameWidth w: Double, frameHeight h: Double) -> Double {
        let cx = (d.x1 + d.x2) / 2 / w
        let height = d.y2 - d.y1
        let central = 1 - min(1, abs(cx - 0.55) / 0.6)   // đèn VN hay ở giữa hoặc bên phải
        let upper = d.y2 / h < 0.6 ? 1.0 : 0.3
        return height * (0.4 + 0.6 * central) * upper
    }

    /// Chọn đèn liên quan trong các detection lớp "traffic light".
    public func pick(_ lights: [Detection], frameWidth w: Double, frameHeight h: Double) -> Detection? {
        lights.filter { $0.y2 - $0.y1 >= minHeightPx }
            .max { Self.score($0, frameWidth: w, frameHeight: h) < Self.score($1, frameWidth: w, frameHeight: h) }
    }

    /// Cập nhật với màu của đèn được chọn ở frame này (nil = không thấy đèn).
    @discardableResult
    public mutating func update(t: Double, light: Detection?, color: LightColor?, speedKmh: Double? = nil) -> TrafficLightState? {
        guard let light, let color else {
            let hold = (speedKmh ?? 0) >= movingKmh ? holdMovingS : holdS
            if let s = state, t - s.lastSeen > hold {
                state = nil
                history.removeAll()
            } else if state != nil {
                state?.box = nil
            }
            return state
        }
        history.append(color)
        if history.count > votes { history.removeFirst(history.count - votes) }
        // bỏ phiếu cả "không rõ": phần lớn frame không rõ màu thì về không rõ (không giữ mãi màu cũ)
        var counts: [LightColor: Int] = [:]
        for c in history { counts[c, default: 0] += 1 }
        let voted = counts.max { $0.value < $1.value }.flatMap { $0.value * 2 > history.count ? $0.key : nil }
        let prev = state?.color ?? .unknown
        let newColor = voted ?? prev
        let since = newColor == prev ? (state?.since ?? t) : t
        state = TrafficLightState(color: newColor, since: since, lastSeen: t, box: light.box, heightPx: light.y2 - light.y1)
        return state
    }

    public mutating func reset() {
        history.removeAll()
        state = nil
    }
}

/// Khi nào nhắc về đèn (bản thử giai đoạn A, chỉnh sau khi có log thật).
public struct LightAlertRules: Equatable, Sendable {
    /// Đèn đỏ: chỉ nhắc khi còn chạy nhanh hơn mức này.
    public var redMinSpeedKmh = 25.0
    /// Có khoảng cách tới ngã tư (OSM): nhắc khi cần phanh mạnh hơn mức này (m/s²) mới dừng kịp trước ngã tư.
    public var redDecelMps2 = 1.5
    /// Không có bản đồ: nhắc khi khung đèn đủ to (gần) và tốc độ ≥ mức này.
    public var redNearHeightPx = 45.0
    public var redNoMapMinSpeedKmh = 30.0
    /// Đèn xanh đã bao lâu (s) mà xe vẫn đứng thì nhắc.
    public var greenWaitS = 2.5

    public init() {}

    public func check(state: TrafficLightState?, t: Double, speedKmh: Double?, junctionM: Double?,
                      stoppedS: Double?) -> VoiceMessage? {
        guard let s = state, s.box != nil else { return nil }
        let key = "light.\(s.color.rawValue).\(Int(s.since * 10))"
        switch s.color {
        case .red:
            guard let v = speedKmh, v >= redMinSpeedKmh, t - s.since >= 0.4 else { return nil }
            let mps = v / 3.6
            if let d = junctionM, d > 0, d < 150 {
                guard mps * mps / (2 * d) >= redDecelMps2 else { return nil }
            } else {
                guard s.heightPx >= redNearHeightPx, v >= redNoMapMinSpeedKmh else { return nil }
            }
            return VoiceMessage(kind: .redLight, text: "Đèn đỏ phía trước", key: key, t: t)
        case .green:
            guard let st = stoppedS, st >= greenWaitS, t - s.since >= greenWaitS else { return nil }
            return VoiceMessage(kind: .lightInfo, text: "Đèn xanh rồi, đi thôi", key: key, t: t)
        default:
            return nil
        }
    }
}

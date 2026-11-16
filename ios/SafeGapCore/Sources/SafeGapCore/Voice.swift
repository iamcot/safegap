// Chính sách giọng nói (docs/DRIVER_ASSIST.md, A3): không nói đè, câu quan trọng trước, mỗi loại có thời gian nghỉ,
// cùng một câu không lặp lại trong một khoảng, câu chờ quá lâu thì bỏ (đã hết đúng lúc).
import Foundation

/// Thứ tự khai báo = độ ưu tiên (đầu tiên quan trọng nhất).
public enum VoiceKind: String, CaseIterable, Codable, Sendable, Comparable {
    case redLight
    case signViolation
    case signReminder
    case lightInfo
    case carFun

    public var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: VoiceKind, b: VoiceKind) -> Bool { a.rank < b.rank }
}

public struct VoiceMessage: Equatable, Sendable {
    public var kind: VoiceKind
    public var text: String
    /// Khoá chống lặp (vd "light.red", "sign.P130"); mặc định là chính câu nói.
    public var key: String
    public var t: Double

    public init(kind: VoiceKind, text: String, key: String? = nil, t: Double) {
        self.kind = kind
        self.text = text
        self.key = key ?? text
        self.t = t
    }
}

public struct VoicePolicy: Equatable, Sendable {
    /// Nghỉ tối thiểu (s) giữa hai câu cùng loại.
    public var kindCooldownS: [VoiceKind: Double] = [
        .redLight: 8, .signViolation: 10, .signReminder: 20, .lightInfo: 15, .carFun: 180,
    ]
    /// Cùng khoá không nói lại trong khoảng này (s).
    public var keyCooldownS: Double = 60
    /// Nghỉ giữa hai câu bất kỳ (s).
    public var gapS: Double = 1.5
    /// Câu chờ lâu hơn (s) thì bỏ.
    public var maxAgeS: Double = 4

    public private(set) var pending: [VoiceMessage] = []
    private var lastKindT: [VoiceKind: Double] = [:]
    private var lastKeyT: [String: Double] = [:]
    private var lastSpokenT: Double?

    public init() {}

    /// Nhận câu vào hàng chờ nếu không đang nghỉ. Trả về false nếu bị bỏ.
    @discardableResult
    public mutating func offer(_ m: VoiceMessage) -> Bool {
        if let k = lastKeyT[m.key], m.t - k < keyCooldownS { return false }
        if let k = lastKindT[m.kind], m.t - k < (kindCooldownS[m.kind] ?? 0) { return false }
        if pending.contains(where: { $0.key == m.key }) { return false }
        pending.append(m)
        return true
    }

    /// Câu nói tiếp theo (đánh dấu là đã nói), nil nếu đang nói / chưa hết nghỉ / không có gì.
    public mutating func next(t: Double, speaking: Bool) -> VoiceMessage? {
        let maxAge = maxAgeS
        pending.removeAll { t - $0.t > maxAge }
        guard !speaking, !pending.isEmpty else { return nil }
        if let last = lastSpokenT, t - last < gapS { return nil }
        guard let i = pending.indices.min(by: { (pending[$0].kind, pending[$0].t) < (pending[$1].kind, pending[$1].t) })
        else { return nil }
        let m = pending.remove(at: i)
        lastSpokenT = t
        lastKindT[m.kind] = t
        lastKeyT[m.key] = t
        // cùng loại đang chờ phải nghỉ theo loại: bỏ luôn
        pending.removeAll { $0.kind == m.kind }
        return m
    }
}

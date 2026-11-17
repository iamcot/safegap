// Biển báo: luật hiệu lực + cảnh báo (docs/DRIVER_ASSIST.md, B1/B5/B6). Luật đọc từ config/signs_vn.json
// theo QCVN 41:2024/BGTVT Điều 26. Model nhận biển (giai đoạn B3/B4) chỉ cần gọi `sighted` khi xe vừa đi qua một biển.
import Foundation

public enum SignScope: String, Codable, Sendable {
    /// Cấm đi vào đoạn đường phía sau biển (P.101–P.120): nhắc ngay khi thấy, giữ tới khi rẽ khỏi đường.
    case entry
    /// Chỉ có hiệu lực ở nơi giao nhau đặt biển (P.123, P.124): hết khi qua ngã tư đầu tiên.
    case atJunction
    /// Tới nơi đường giao nhau tiếp giáp hoặc biển hết cấm (P.125–P.127, P.130, P.131).
    case untilJunction
    /// Tới hết cự ly trên biển phụ S.501 (P.121, P.128).
    case distance
    /// Biển hết cấm (DP.133, DP.134, DP.135).
    case end
}

public struct SignRule: Codable, Equatable, Sendable {
    public var name: String
    public var scope: SignScope
    public var say: String?
    public var vehicle: String?
    public var forbidTurns: [TurnDirection]?
    public var speedLimit: Bool?
    public var noStop: Bool?
    public var noPark: Bool?
    /// "odd" / "even": chỉ áp dụng ngày lẻ / chẵn.
    public var parity: String?
    /// Biển hết cấm: các mã bị xoá ("*" = tất cả).
    public var ends: [String]?

    public init(name: String, scope: SignScope, say: String? = nil, vehicle: String? = nil, forbidTurns: [TurnDirection]? = nil,
                speedLimit: Bool? = nil, noStop: Bool? = nil, noPark: Bool? = nil, parity: String? = nil, ends: [String]? = nil) {
        self.name = name; self.scope = scope; self.say = say; self.vehicle = vehicle; self.forbidTurns = forbidTurns
        self.speedLimit = speedLimit; self.noStop = noStop; self.noPark = noPark; self.parity = parity; self.ends = ends
    }
}

public struct SignAlertConfig: Codable, Equatable, Sendable {
    public var noStopAfterS: Double = 3
    public var noParkAfterS: Double = 60
    public var turnReminderM: Double = 80
    public var turnWarnM: Double = 40
    public var speedMarginKmh: Double = 3
    public var speedHoldS: Double = 3
    public var sameSignM: Double = 30
    /// Qua ngã tư trong khoảng này sau biển thì không xoá biển (ngã tư nằm sau lưng biển).
    public var minAfterSignM: Double = 15
    public var safetyExpireNoMapM: Double = 1500
    public var safetyExpireM: Double = 5000

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SignAlertConfig()
        noStopAfterS = try c.decodeIfPresent(Double.self, forKey: .noStopAfterS) ?? d.noStopAfterS
        noParkAfterS = try c.decodeIfPresent(Double.self, forKey: .noParkAfterS) ?? d.noParkAfterS
        turnReminderM = try c.decodeIfPresent(Double.self, forKey: .turnReminderM) ?? d.turnReminderM
        turnWarnM = try c.decodeIfPresent(Double.self, forKey: .turnWarnM) ?? d.turnWarnM
        speedMarginKmh = try c.decodeIfPresent(Double.self, forKey: .speedMarginKmh) ?? d.speedMarginKmh
        speedHoldS = try c.decodeIfPresent(Double.self, forKey: .speedHoldS) ?? d.speedHoldS
        sameSignM = try c.decodeIfPresent(Double.self, forKey: .sameSignM) ?? d.sameSignM
        minAfterSignM = try c.decodeIfPresent(Double.self, forKey: .minAfterSignM) ?? d.minAfterSignM
        safetyExpireNoMapM = try c.decodeIfPresent(Double.self, forKey: .safetyExpireNoMapM) ?? d.safetyExpireNoMapM
        safetyExpireM = try c.decodeIfPresent(Double.self, forKey: .safetyExpireM) ?? d.safetyExpireM
    }
}

public struct SignConfig: Codable, Equatable, Sendable {
    public var source: String?
    public var signs: [String: SignRule]
    public var alerts: SignAlertConfig

    public init(source: String? = nil, signs: [String: SignRule], alerts: SignAlertConfig = SignAlertConfig()) {
        self.source = source; self.signs = signs; self.alerts = alerts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        signs = try c.decode([String: SignRule].self, forKey: .signs)
        alerts = try c.decodeIfPresent(SignAlertConfig.self, forKey: .alerts) ?? SignAlertConfig()
    }

    public static func decode(_ data: Data) throws -> SignConfig { try JSONDecoder().decode(SignConfig.self, from: data) }
}

/// Khung giờ theo phút trong ngày (S.508), có thể qua nửa đêm (vd 22h–6h).
public struct TimeWindow: Codable, Equatable, Sendable {
    public var startMin: Int
    public var endMin: Int
    public init(startMin: Int, endMin: Int) { self.startMin = startMin; self.endMin = endMin }
    public init(fromHour a: Int, toHour b: Int) { self.init(startMin: a * 60, endMin: b * 60) }

    public func contains(minuteOfDay m: Int) -> Bool {
        startMin <= endMin ? (m >= startMin && m < endMin) : (m >= startMin || m < endMin)
    }

    public var label: String {
        func f(_ m: Int) -> String { m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h\(String(format: "%02d", m % 60))" }
        return "\(f(startMin))–\(f(endMin))"
    }
}

/// Một lần nhận ra biển (xe vừa đi qua biển).
public struct SignSighting: Equatable, Sendable {
    public var code: String
    /// Số trên biển (tốc độ tối đa...).
    public var value: Int?
    /// Biển phụ S.508.
    public var window: TimeWindow?
    /// Biển phụ S.501 (m).
    public var distanceM: Double?
    public init(code: String, value: Int? = nil, window: TimeWindow? = nil, distanceM: Double? = nil) {
        self.code = code; self.value = value; self.window = window; self.distanceM = distanceM
    }
}

/// Lệnh cấm đang có hiệu lực.
public struct ActiveSign: Equatable, Sendable, Identifiable {
    public var id: String { "\(code)@\(Int(startOdo))" }
    public var code: String
    public var rule: SignRule
    public var value: Int?
    public var window: TimeWindow?
    public var startOdo: Double
    public var startT: Double
    /// Hết hiệu lực khi odometer tới mức này (S.501), nil = theo ngã tư / biển hết cấm.
    public var untilOdo: Double?
    /// Đang áp dụng ngay lúc này (khung giờ, ngày chẵn/lẻ, loại xe).
    public var applies: Bool = true
}

/// Điều kiện xe tại một thời điểm, cho `SignEngine.update`.
public struct DriveContext: Equatable, Sendable {
    public var t: Double
    public var odometer: Double
    public var minuteOfDay: Int
    public var dayOfMonth: Int
    public var speedKmh: Double?
    /// Số giây đứng yên (nil = đang chạy).
    public var stoppedS: Double?
    /// Đứng vì kẹt xe (xe trước sát và cũng đứng) hoặc chờ đèn đỏ: không tính là dừng/đỗ sai.
    public var stopExcused: Bool
    /// Khoảng cách tới ngã tư kế tiếp (nil = không có bản đồ).
    public var junctionM: Double?
    public var junctionPassed: Bool
    public var turn: TurnEvent?
    public var turning: TurnDirection?
    /// "car" / "truck": loại xe mình.
    public var vehicle: String

    public init(t: Double, odometer: Double, minuteOfDay: Int = 12 * 60, dayOfMonth: Int = 1, speedKmh: Double? = nil,
                stoppedS: Double? = nil, stopExcused: Bool = false, junctionM: Double? = nil, junctionPassed: Bool = false,
                turn: TurnEvent? = nil, turning: TurnDirection? = nil, vehicle: String = "car") {
        self.t = t; self.odometer = odometer; self.minuteOfDay = minuteOfDay; self.dayOfMonth = dayOfMonth
        self.speedKmh = speedKmh; self.stoppedS = stoppedS; self.stopExcused = stopExcused; self.junctionM = junctionM
        self.junctionPassed = junctionPassed; self.turn = turn; self.turning = turning; self.vehicle = vehicle
    }
}

/// Biển thấy từ xa: hiệu lực bắt đầu khi xe tới chỗ cắm biển (odometer `atOdo`), không phải lúc thấy.
public struct PendingSign: Equatable, Sendable {
    public var sighting: SignSighting
    public var atOdo: Double
    /// Biển của đường nhánh (cấm đi vào ở miệng đường bên phải, biển giữa dải phân cách bên trái): chỉ áp dụng
    /// khi xe rẽ hướng này gần chỗ cắm biển; đi thẳng qua thì bỏ.
    public var onlyIfTurn: TurnDirection?
}

public struct SignEngine: Equatable, Sendable {
    public var config: SignConfig
    public private(set) var active: [ActiveSign] = []
    public private(set) var pending: [PendingSign] = []
    private var overSpeedSince: Double?

    public init(config: SignConfig) { self.config = config }

    public static func turnName(_ d: TurnDirection) -> String {
        switch d {
        case .left: return "rẽ trái"
        case .right: return "rẽ phải"
        case .uturn: return "quay đầu"
        }
    }

    /// Xe vừa đi qua một biển. Trả về câu cần nói ngay (biển cấm đi vào, có hiệu lực lúc này).
    public mutating func sighted(_ s: SignSighting, odometer: Double, t: Double, minuteOfDay: Int, dayOfMonth: Int,
                                 vehicle: String = "car") -> [VoiceMessage] {
        guard let rule = config.signs[s.code] else { return [] }
        if rule.scope == .end {
            let ends = rule.ends ?? []
            active.removeAll { ends.contains("*") || ends.contains($0.code) }
            return []
        }
        // cùng biển (nhận lại vài lần khi đi qua, hoặc biển lặp lại ngay sau): bỏ
        let same = config.alerts.sameSignM
        if active.contains(where: { $0.code == s.code && abs(odometer - $0.startOdo) < same && $0.value == s.value }) {
            return []
        }
        // biển cùng loại mới thay biển cũ (vd tốc độ 60 → 40)
        active.removeAll { $0.code == s.code || (rule.speedLimit == true && $0.rule.speedLimit == true) }
        var a = ActiveSign(code: s.code, rule: rule, value: s.value, window: s.window, startOdo: odometer, startT: t,
                           untilOdo: s.distanceM.map { odometer + $0 })
        a.applies = Self.applies(a, minuteOfDay: minuteOfDay, dayOfMonth: dayOfMonth, vehicle: vehicle)
        active.append(a)
        guard rule.scope == .entry, a.applies, let say = rule.say else { return [] }
        let text = s.window.map { say + " " + $0.label } ?? say
        return [VoiceMessage(kind: .signViolation, text: text, key: "sign.\(a.id)", t: t)]
    }

    /// Biển thấy cách `aheadM` mét phía trước. Biển cấm đi vào nói ngay (để kịp dừng); biển khác chờ tới chỗ cắm biển
    /// mới có hiệu lực (biển nằm sau ngã tư thì ngã tư đó không xoá nó). Rẽ trước khi tới biển thì bỏ.
    public mutating func sightedAhead(_ s: SignSighting, aheadM: Double, odometer: Double, t: Double, minuteOfDay: Int,
                                      dayOfMonth: Int, vehicle: String = "car") -> [VoiceMessage] {
        guard let rule = config.signs[s.code] else { return [] }
        if rule.scope == .entry || aheadM <= 5 {
            return sighted(s, odometer: odometer, t: t, minuteOfDay: minuteOfDay, dayOfMonth: dayOfMonth, vehicle: vehicle)
        }
        let at = odometer + aheadM
        let same = config.alerts.sameSignM
        if pending.contains(where: { $0.sighting.code == s.code && abs($0.atOdo - at) < same }) { return [] }
        pending.append(PendingSign(sighting: s, atOdo: at))
        return []
    }

    /// Biển cấm đi vào của đường nhánh / chiều ngược lại: chỉ nói nếu xe rẽ `turn` (trái gồm cả quay đầu)
    /// trong khoảng ±`turnWindowM` quanh chỗ cắm biển.
    public mutating func sightedIfTurn(_ s: SignSighting, turn: TurnDirection, aheadM: Double, odometer: Double) {
        guard config.signs[s.code] != nil else { return }
        let at = odometer + aheadM
        if pending.contains(where: { $0.sighting.code == s.code && $0.onlyIfTurn == turn && abs($0.atOdo - at) < config.alerts.sameSignM }) {
            return
        }
        pending.append(PendingSign(sighting: s, atOdo: at, onlyIfTurn: turn))
    }

    public static let turnWindowM = 30.0

    static func applies(_ a: ActiveSign, minuteOfDay: Int, dayOfMonth: Int, vehicle: String) -> Bool {
        if let w = a.window, !w.contains(minuteOfDay: minuteOfDay) { return false }
        if let v = a.rule.vehicle, v != vehicle { return false }
        switch a.rule.parity {
        case "odd": return dayOfMonth % 2 == 1
        case "even": return dayOfMonth % 2 == 0
        default: return true
        }
    }

    /// Gọi mỗi frame: hết hiệu lực + câu cảnh báo / nhắc.
    public mutating func update(_ c: DriveContext) -> [VoiceMessage] {
        let al = config.alerts
        var out: [VoiceMessage] = []
        // biển thấy từ xa: tới chỗ cắm thì bắt đầu hiệu lực; rẽ khỏi đường trước khi tới thì bỏ
        if c.turn != nil {
            pending.removeAll { $0.onlyIfTurn == nil }
        } else {
            let ready = pending.filter { $0.onlyIfTurn == nil && c.odometer >= $0.atOdo }
            pending.removeAll { $0.onlyIfTurn == nil && c.odometer >= $0.atOdo }
            for p in ready {
                out += sighted(p.sighting, odometer: p.atOdo, t: c.t, minuteOfDay: c.minuteOfDay,
                               dayOfMonth: c.dayOfMonth, vehicle: c.vehicle)
            }
        }
        // hết hiệu lực
        active.removeAll { a in
            if let u = a.untilOdo, c.odometer >= u { return true }
            // biển đặt ngay sau ngã tư: ngã tư vừa qua (sau lưng biển) không tính
            if c.junctionPassed, a.rule.scope == .atJunction || a.rule.scope == .untilJunction,
               c.odometer - a.startOdo > al.minAfterSignM { return true }
            // rẽ ở ngã tư cũng là qua ngã tư; rẽ khỏi đường thì biển "cấm đi vào" không còn áp dụng
            if c.turn != nil, a.rule.scope != .distance { return true }
            let limit = c.junctionM == nil ? al.safetyExpireNoMapM : al.safetyExpireM
            return c.odometer - a.startOdo > limit
        }
        // biển đường nhánh: xe đang rẽ / vừa rẽ đúng hướng gần chỗ cắm biển thì áp dụng (sau bước xoá vì rẽ)
        let win = Self.turnWindowM
        let dir = c.turning ?? c.turn?.direction
        var fired: [PendingSign] = []
        pending.removeAll { p in
            guard let want = p.onlyIfTurn else { return false }
            if let d = dir, abs(c.odometer - p.atOdo) <= win, d == want || (want == .left && d == .uturn) {
                fired.append(p)
                return true
            }
            return c.odometer > p.atOdo + win
        }
        for p in fired {
            out += sighted(p.sighting, odometer: c.odometer, t: c.t, minuteOfDay: c.minuteOfDay,
                           dayOfMonth: c.dayOfMonth, vehicle: c.vehicle)
        }
        for i in active.indices {
            active[i].applies = Self.applies(active[i], minuteOfDay: c.minuteOfDay, dayOfMonth: c.dayOfMonth, vehicle: c.vehicle)
        }

        var overSpeed = false
        for a in active where a.applies {
            let key = "sign.\(a.id)"
            let r = a.rule
            if r.noStop == true, let st = c.stoppedS, st >= al.noStopAfterS, !c.stopExcused {
                out.append(VoiceMessage(kind: .signViolation, text: "Đang trong đoạn cấm dừng đỗ", key: key + ".stop", t: c.t))
            }
            if r.noPark == true, let st = c.stoppedS, st >= al.noParkAfterS, !c.stopExcused {
                out.append(VoiceMessage(kind: .signViolation, text: "Đoạn này cấm đỗ xe", key: key + ".park", t: c.t))
            }
            if let turns = r.forbidTurns, !turns.isEmpty {
                let names = turns.map(Self.turnName).joined(separator: " và ")
                // quay đầu bắt đầu giống rẽ trái: biển cấm quay đầu cũng cảnh báo khi xe bắt đầu rẽ trái
                let banned: TurnDirection? = c.turning.flatMap { dir in
                    turns.contains(dir) ? dir : (dir == .left && turns.contains(.uturn) ? .uturn : nil)
                }
                if let dir = banned, c.junctionM.map({ $0 < al.turnWarnM }) ?? true {
                    out.append(VoiceMessage(kind: .signViolation, text: "Cấm \(Self.turnName(dir))!", key: key + ".turn", t: c.t))
                } else if c.turning == nil, let j = c.junctionM, j > 0, j <= al.turnReminderM {
                    out.append(VoiceMessage(kind: .signReminder, text: "Ngã tư phía trước cấm \(names)", key: key + ".remind", t: c.t))
                }
            }
            if r.speedLimit == true, let lim = a.value, let v = c.speedKmh, v > Double(lim) + al.speedMarginKmh {
                overSpeed = true
                if let since = overSpeedSince, c.t - since >= al.speedHoldS {
                    out.append(VoiceMessage(kind: .signViolation, text: "Quá tốc độ, giới hạn \(lim)", key: key + ".speed", t: c.t))
                }
            }
        }
        if overSpeed { overSpeedSince = overSpeedSince ?? c.t } else { overSpeedSince = nil }
        return out
    }

    public mutating func reset() {
        active.removeAll()
        pending.removeAll()
        overSpeedSince = nil
    }
}

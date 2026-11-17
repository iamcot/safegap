// Bảng luật + quyết định cảnh báo có hysteresis (port từ proto/alert.py, mục 3.6).
import Foundation

public enum Level: String, Codable, Sendable {
    case none = "NONE"      // không cảnh báo (chậm / không có xe cùng làn)
    case green = "GREEN"
    case yellow = "YELLOW"
    case red = "RED"
}

public struct LawTable: Sendable {
    public let rows: [LawConfig.Row]
    public let belowFirstHeadwayS: Double?
    /// Quy tắc N giây không xuống dưới mức này (m).
    public static let headwayFloorM = 5.0

    public init(_ law: LawConfig) {
        rows = law.table.sorted { $0.maxKmh < $1.maxKmh }
        belowFirstHeadwayS = law.belowFirstHeadwayS
        precondition(!rows.isEmpty, "Bảng luật rỗng")
    }

    /// Tốc độ trên mốc cuối dùng d_min của mốc cuối. Dưới mốc đầu: quy tắc N giây nếu có cấu hình.
    public func dMin(speedKmh: Double) -> Double {
        if let hw = belowFirstHeadwayS, speedKmh < rows[0].maxKmh {
            return min(rows[0].dMinM, max(Self.headwayFloorM, speedKmh / 3.6 * hw))
        }
        for r in rows where speedKmh <= r.maxKmh { return r.dMinM }
        return rows[rows.count - 1].dMinM
    }
}

public func classify(distanceM: Double, dMinM: Double, redRatio: Double = 0.9, yellowRatio: Double = 1.1) -> Level {
    if distanceM < redRatio * dMinM { return .red }
    if distanceM < yellowRatio * dMinM { return .yellow }
    return .green
}

/// Chỉ đổi trạng thái khi trạng thái mới giữ ổn định >= hold_s. Âm thanh khi vào RED, có cooldown.
public final class AlertState {
    public let law: LawTable
    public let config: AlertConfig
    public private(set) var level: Level = .none
    public private(set) var dMin: Double?
    private var candidate: Level = .none
    private var candidateSince: Double?
    private var lastSound: Double?

    public init(law: LawTable, config: AlertConfig) {
        self.law = law
        self.config = config
    }

    public func rawLevel(t: Double, speedKmh: Double?, distanceM: Double?) -> Level {
        guard let v = speedKmh, v >= config.minSpeedKmh, let d = distanceM else {
            dMin = nil
            return .none
        }
        let manual = config.manualDMinM ?? 0
        let dm = manual != 0 ? manual : law.dMin(speedKmh: v)
        dMin = dm
        return classify(distanceM: d, dMinM: dm, redRatio: config.redRatio, yellowRatio: config.yellowRatio)
    }

    /// Trả về (level, phát âm thanh?).
    public func update(t: Double, speedKmh: Double?, distanceM: Double?) -> (level: Level, sound: Bool) {
        let raw = rawLevel(t: t, speedKmh: speedKmh, distanceM: distanceM)
        if raw == level {
            candidate = raw
            candidateSince = nil
        } else if raw != candidate || candidateSince == nil {
            candidate = raw
            candidateSince = t
        }
        if candidate != level, let since = candidateSince, t - since >= config.holdS {
            let prev = level
            level = candidate
            candidateSince = nil
            if level == .red, prev != .red {
                if lastSound == nil || t - lastSound! >= config.soundCooldownS {
                    lastSound = t
                    return (level, true)
                }
            }
        }
        return (level, false)
    }
}

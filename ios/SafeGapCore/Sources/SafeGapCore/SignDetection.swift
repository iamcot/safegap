// Biển từ model dò biển (docs/DRIVER_ASSIST.md, B3): model trả về nhóm biển (SIGN_GROUPS trong proto/dataset.py),
// tracker bỏ phiếu qua nhiều frame, lọc biển dán trên thân xe, rồi đổi nhóm → SignSighting cho SignEngine.
// Nhóm chưa đủ để biết mã cụ thể (cấm rẽ trái hay phải, tốc độ bao nhiêu) thì chỉ hiện, chờ classifier B4.
import Foundation

public enum SignGroup: String, CaseIterable, Codable, Sendable {
    case noEntry = "no_entry"
    case noStopPark = "no_stop_park"
    case noTurn = "no_turn"
    case speedLimit = "speed_limit"
    case prohibitOther = "prohibit_other"
    case mandatory
    case warning
    case endRestriction = "end_restriction"
    case other = "sign_other"

    /// Chữ ngắn để vẽ trên khung.
    public var label: String {
        switch self {
        case .noEntry: return "Cấm đi vào"
        case .noStopPark: return "Cấm dừng/đỗ"
        case .noTurn: return "Cấm rẽ"
        case .speedLimit: return "Tốc độ"
        case .prohibitOther: return "Biển cấm"
        case .mandatory: return "Hiệu lệnh"
        case .warning: return "Nguy hiểm"
        case .endRestriction: return "Hết cấm"
        case .other: return "Biển"
        }
    }

    /// Mã QCVN đưa vào SignEngine khi chỉ biết nhóm. nil = chỉ hiện, chưa đủ để áp luật.
    /// Cấm dừng/đỗ: lấy P.130 (chặt hơn, cấm cả dừng) cho tới khi có classifier phân biệt P.130 / P.131.
    public var sightingCode: String? {
        switch self {
        case .noEntry: return "P.102"
        case .noStopPark: return "P.130"
        case .speedLimit: return "P.127"
        default: return nil
        }
    }

    /// Biển cấm / hiệu lệnh màu đỏ-xanh nổi bật: vẽ đậm hơn.
    public var isRegulatory: Bool {
        switch self {
        case .noEntry, .noStopPark, .noTurn, .speedLimit, .prohibitOther, .mandatory, .endRestriction: return true
        default: return false
        }
    }
}

/// Vì sao biển không áp dụng cho xe mình (theo vị trí cắm biển).
public enum SignPlacement: String, Codable, Sendable {
    /// Biển bên phải / phía trên làn mình: áp dụng.
    case applies
    /// Biển nằm bên trái làn mình (dải phân cách, giữa đường 2 chiều): hiệu lực là phần đường bên trái biển
    /// (chiều ngược lại), không phải làn mình.
    case leftOfUs
    /// Biển xa bên phải (đường ngang, đường nhánh ở ngã tư).
    case farRight
    /// Biển quay xiên / quay ngang (khung hẹp): dành cho hướng đi khác.
    case turnedAway
}

/// Một biển đã xác nhận (đủ phiếu) ở frame này.
public struct ConfirmedSign: Equatable, Sendable {
    public var group: SignGroup
    public var box: Box
    public var conf: Double
    public var t: Double
    /// Ước lượng từ chiều cao khung (biển tròn ~0,7 m): khoảng cách phía trước và lệch ngang (m, + = phải).
    public var distanceM: Double?
    public var lateralM: Double?
    public var placement: SignPlacement = .applies

    public var applies: Bool { placement == .applies }
}

public struct SignDetectionTracker: Equatable, Sendable {
    /// Số frame thấy cùng biển (trong `windowS`) mới tin.
    public var minHits = 3
    public var windowS = 1.5
    public var minConf = 0.35
    /// Khung nhỏ hơn (pixel cao) thì bỏ: quá xa, dễ nhầm.
    public var minHeightPx = 12.0
    /// Tâm khung thấp hơn tỉ lệ này của ảnh thì bỏ (vạch sơn, biển trên đuôi xe thấp).
    public var maxCenterY = 0.8
    /// Đã báo một nhóm thì không báo lại nhóm đó trong khoảng này (s), kể cả khi track bị đứt.
    public var cooldownS = 8.0
    /// Cỡ biển thật (m) để ước lượng khoảng cách: biển tròn / tam giác trong đô thị 70 cm (QCVN 41).
    public var signSizeM = 0.7
    /// Biển có hiệu lực cho phần đường bên trái nó (theo hướng nhìn tài xế): biển lệch trái quá mức này
    /// (m, so với tâm camera) là biển của chiều ngược lại / dải phân cách.
    /// Xe đi làn trái cạnh dải phân cách thì biển giữa đường chỉ lệch ~ -2,5 m, sai số ước lượng ±1 m: để -1.
    public var minLateralM = -1.0
    /// Đường một chiều (OSM): biển cắm bên trái cũng dành cho mình (app đặt theo đường đang chạy).
    public var leftSideApplies = false
    /// Biển còn xa hơn ngần này (m) thì chưa chốt: ở xa biển nào cũng gần tâm ảnh, vị trí trái / phải chưa chắc.
    /// Chốt khi tới gần, hoặc khi biển ra khỏi khung hình (đi qua) mà vẫn đủ phiếu.
    public var confirmWithinM = 30.0
    /// Biển lệch phải xa hơn mức này là biển của đường ngang / nhánh rẽ. App chỉnh theo số làn (OSM).
    public var maxLateralM = 10.0
    /// Khung hẹp hơn tỉ lệ rộng/cao này: biển quay xiên, không hướng về mình.
    public var minAspect = 0.6

    struct Track: Equatable, Sendable {
        var group: SignGroup
        var box: Box
        var hits: [Double]
        var conf: Double
        var placement: SignPlacement = .applies
        var distanceM: Double?
        var lateralM: Double?
        var lastT: Double
        var reported: Bool
        var totalHits = 0
    }

    private(set) var tracks: [Track] = []
    private var lastReported: [SignGroup: Double] = [:]

    public init() {}

    /// Biển đang thấy (đã đủ phiếu) để vẽ.
    public var visible: [ConfirmedSign] {
        tracks.filter { $0.hits.count >= minHits }.map {
            ConfirmedSign(group: $0.group, box: $0.box, conf: $0.conf, t: $0.lastT, distanceM: $0.distanceM,
                          lateralM: $0.lateralM, placement: $0.placement)
        }
    }

    /// Vị trí biển so với xe (từ khung + tiêu cự) và biển có dành cho làn mình không.
    /// `roadBend(z)`: đường cong sang phải bao nhiêu mét ở khoảng cách z (từ OSM). Đường cong thì biển bên lề trông như
    /// lệch trái / phải so với hướng thẳng; trừ đi độ cong để so với mép đường thật.
    public func place(_ b: Box, frameWidth w: Double, fPx: Double?,
                      roadBend: ((Double) -> Double?)? = nil) -> (SignPlacement, Double?, Double?) {
        let bw = b.x2 - b.x1, bh = b.y2 - b.y1
        guard bh > 0 else { return (.applies, nil, nil) }
        if bw / bh < minAspect { return (.turnedAway, nil, nil) }
        guard let f = fPx, f > 0 else { return (.applies, nil, nil) }
        let z = f * signSizeM / bh
        let x = ((b.x1 + b.x2) / 2 - w / 2) * z / f - (roadBend?(z) ?? 0)
        if x < (leftSideApplies ? -maxLateralM : minLateralM) { return (.leftOfUs, z, x) }
        if x > maxLateralM { return (.farRight, z, x) }
        return (.applies, z, x)
    }

    /// Cập nhật với khung biển của model ở frame này; `vehicles` để bỏ biển nằm trên thân xe.
    /// Trả về các biển vừa được xác nhận lần đầu (mỗi biển một lần).
    public mutating func update(t: Double, signs: [Detection], vehicles: [Detection],
                                frameWidth w: Double, frameHeight h: Double, fPx: Double? = nil,
                                roadBend: ((Double) -> Double?)? = nil) -> [ConfirmedSign] {
        let windowS = self.windowS
        var out: [ConfirmedSign] = []
        // biển vừa ra khỏi khung hình mà chưa chốt (còn xa lúc thấy lần cuối): chốt theo vị trí lần cuối
        for tr in tracks where t - tr.lastT > windowS && !tr.reported && tr.totalHits >= minHits {
            if let c = confirm(tr, t: t) { out.append(c) }
        }
        tracks.removeAll { t - $0.lastT > windowS }
        for i in tracks.indices { tracks[i].hits.removeAll { t - $0 > windowS } }

        for d in signs {
            guard let g = SignGroup(rawValue: d.cls), d.conf >= minConf, d.y2 - d.y1 >= minHeightPx else { continue }
            let cx = (d.x1 + d.x2) / 2, cy = (d.y1 + d.y2) / 2
            guard cy / h <= maxCenterY else { continue }
            // biển nằm gọn trong khung xe (quảng cáo, biển trên đuôi xe tải): bỏ
            if vehicles.contains(where: { cx > $0.x1 && cx < $0.x2 && cy > $0.y1 && cy < $0.y2 && $0.width > d.width * 2 }) {
                continue
            }
            let (pl, z, x) = place(d.box, frameWidth: w, fPx: fPx, roadBend: roadBend)
            if let j = bestTrack(for: d, group: g) {
                tracks[j].box = d.box
                // khung mới nhất (gần nhất, to nhất) quyết định vị trí
                tracks[j].placement = pl
                tracks[j].distanceM = z
                tracks[j].lateralM = x
                tracks[j].hits.append(t)
                tracks[j].totalHits += 1
                tracks[j].conf = max(tracks[j].conf, d.conf)
                tracks[j].lastT = t
            } else {
                tracks.append(Track(group: g, box: d.box, hits: [t], conf: d.conf, placement: pl, distanceM: z, lateralM: x,
                                    lastT: t, reported: false, totalHits: 1))
            }
        }

        for i in tracks.indices where !tracks[i].reported && tracks[i].hits.count >= minHits
            && (tracks[i].distanceM ?? 0) <= confirmWithinM {
            tracks[i].reported = true
            if let c = confirm(tracks[i], t: t) { out.append(c) }
        }
        return out
    }

    private mutating func confirm(_ tr: Track, t: Double) -> ConfirmedSign? {
        let c = ConfirmedSign(group: tr.group, box: tr.box, conf: tr.conf, t: t, distanceM: tr.distanceM,
                              lateralM: tr.lateralM, placement: tr.placement)
        // biển không dành cho làn mình: vẫn trả về (để vẽ mờ) nhưng không chiếm lượt cooldown
        if c.applies {
            if let last = lastReported[tr.group], t - last < cooldownS { return nil }
            lastReported[tr.group] = t
        }
        return c
    }

    /// Track cùng nhóm gần nhất: khung chồng nhau, hoặc tâm cách < 2 lần bề rộng (biển trôi ra mép khi xe tới gần).
    private func bestTrack(for d: Detection, group: SignGroup) -> Int? {
        var best: (i: Int, score: Double)?
        for (i, tr) in tracks.enumerated() where tr.group == group {
            let b = tr.box
            let dx = (b.x1 + b.x2) / 2 - (d.x1 + d.x2) / 2, dy = (b.y1 + b.y2) / 2 - (d.y1 + d.y2) / 2
            let dist = (dx * dx + dy * dy).squareRoot()
            let reach = 2 * max(d.width, b.x2 - b.x1)
            guard dist <= reach else { continue }
            if best == nil || dist < best!.score { best = (i, dist) }
        }
        return best?.i
    }

    public mutating func reset() {
        tracks.removeAll()
    }
}

public extension ConfirmedSign {
    /// Biển cho SignEngine, nil khi nhóm chưa đủ để áp luật hoặc biển không dành cho làn mình.
    var sighting: SignSighting? {
        guard applies else { return nil }
        return group.sightingCode.map { SignSighting(code: $0) }
    }
}

public extension SignEngine {
    /// Biển ở miệng đường nhánh bên phải: lệch phải hơn mức này (m) thì coi là biển của đường nhánh.
    static let sideRoadLateralM = 5.0

    /// Đưa biển model vừa xác nhận vào luật, theo chỗ cắm biển (QCVN 41: biển có hiệu lực cho phần đường bên trái nó):
    /// - biển bên phải / trên làn mình: có hiệu lực từ chỗ cắm biển (chờ xe tới đó);
    /// - biển cấm đi vào bên trái (dải phân cách, giữa đường 2 chiều): chỉ khi xe rẽ trái / quay đầu vào chiều ngược lại;
    /// - biển cấm đi vào xa bên phải (miệng đường nhánh): chỉ khi xe rẽ phải vào đó;
    /// - biển khác không dành cho làn mình, biển quay xiên: bỏ.
    mutating func feed(_ c: ConfirmedSign, odometer: Double, t: Double, minuteOfDay: Int, dayOfMonth: Int,
                       vehicle: String = "car") -> [VoiceMessage] {
        guard let code = c.group.sightingCode, let rule = config.signs[code] else { return [] }
        let s = SignSighting(code: code)
        let ahead = max(0, c.distanceM ?? 0)
        let lateral = c.lateralM ?? 0
        switch c.placement {
        case .applies where rule.scope == .entry && lateral > Self.sideRoadLateralM, .farRight where rule.scope == .entry:
            sightedIfTurn(s, turn: .right, aheadM: ahead, odometer: odometer)
            return []
        case .leftOfUs where rule.scope == .entry:
            sightedIfTurn(s, turn: .left, aheadM: ahead, odometer: odometer)
            return []
        case .applies:
            return sightedAhead(s, aheadM: ahead, odometer: odometer, t: t, minuteOfDay: minuteOfDay,
                                dayOfMonth: dayOfMonth, vehicle: vehicle)
        default:
            return []
        }
    }
}

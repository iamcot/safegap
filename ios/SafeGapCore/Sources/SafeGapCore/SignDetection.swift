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

/// Một biển đã xác nhận (đủ phiếu) ở frame này.
public struct ConfirmedSign: Equatable, Sendable {
    public var group: SignGroup
    public var box: Box
    public var conf: Double
    public var t: Double
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

    struct Track: Equatable, Sendable {
        var group: SignGroup
        var box: Box
        var hits: [Double]
        var conf: Double
        var lastT: Double
        var reported: Bool
    }

    private(set) var tracks: [Track] = []
    private var lastReported: [SignGroup: Double] = [:]

    public init() {}

    /// Biển đang thấy (đã đủ phiếu) để vẽ.
    public var visible: [ConfirmedSign] {
        tracks.filter { $0.hits.count >= minHits }.map { ConfirmedSign(group: $0.group, box: $0.box, conf: $0.conf, t: $0.lastT) }
    }

    /// Cập nhật với khung biển của model ở frame này; `vehicles` để bỏ biển nằm trên thân xe.
    /// Trả về các biển vừa được xác nhận lần đầu (mỗi biển một lần).
    public mutating func update(t: Double, signs: [Detection], vehicles: [Detection],
                                frameWidth _: Double, frameHeight h: Double) -> [ConfirmedSign] {
        let windowS = self.windowS
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
            if let j = bestTrack(for: d, group: g) {
                tracks[j].box = d.box
                tracks[j].hits.append(t)
                tracks[j].conf = max(tracks[j].conf, d.conf)
                tracks[j].lastT = t
            } else {
                tracks.append(Track(group: g, box: d.box, hits: [t], conf: d.conf, lastT: t, reported: false))
            }
        }

        var out: [ConfirmedSign] = []
        for i in tracks.indices where !tracks[i].reported && tracks[i].hits.count >= minHits {
            tracks[i].reported = true
            let g = tracks[i].group
            if let last = lastReported[g], t - last < cooldownS { continue }
            lastReported[g] = t
            out.append(ConfirmedSign(group: g, box: tracks[i].box, conf: tracks[i].conf, t: t))
        }
        return out
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
    /// Biển cho SignEngine, nil khi nhóm chưa đủ để áp luật.
    var sighting: SignSighting? {
        group.sightingCode.map { SignSighting(code: $0) }
    }
}

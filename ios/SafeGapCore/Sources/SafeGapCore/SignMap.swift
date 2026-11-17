// Bản đồ biển tự học trên tuyến hay đi (docs/DRIVER_ASSIST.md, B3c): mỗi biển camera xác nhận (dành cho làn mình) được
// đổi ra toạ độ (GPS xe + hướng đi + khoảng cách / lệch ngang ước lượng từ khung hình) và lưu lại. Lần sau đi qua,
// app nhắc từ bản đồ trước cả khi camera thấy, và vẫn nhắc nếu camera sót (biển bị xe che, biển nhỏ, model kém).
// Biển nhiều lần đi qua mà camera không thấy nữa (đã bị gỡ) thì tự xoá.
import Foundation

public enum Geo {
    public static let mPerLat = 111_320.0

    public static func mPerLon(_ lat: Double) -> Double { mPerLat * cos(lat * .pi / 180) }

    /// Điểm cách (lat, lon) `forwardM` mét theo hướng `courseDeg` (0 = bắc, theo chiều kim đồng hồ) và `rightM` sang phải.
    public static func offset(lat: Double, lon: Double, courseDeg: Double, forwardM: Double, rightM: Double)
        -> (lat: Double, lon: Double) {
        let c = courseDeg * .pi / 180
        // hướng tới (đông, bắc) = (sin c, cos c); bên phải = (cos c, -sin c)
        let east = forwardM * sin(c) + rightM * cos(c)
        let north = forwardM * cos(c) - rightM * sin(c)
        return (lat + north / mPerLat, lon + east / mPerLon(lat))
    }

    /// Vị trí điểm (lat2, lon2) so với xe ở (lat, lon) đi hướng `courseDeg`: (phía trước, sang phải), mét.
    public static func local(lat: Double, lon: Double, courseDeg: Double, toLat: Double, toLon: Double)
        -> (forward: Double, right: Double) {
        let east = (toLon - lon) * mPerLon(lat), north = (toLat - lat) * mPerLat
        let c = courseDeg * .pi / 180
        return (east * sin(c) + north * cos(c), east * cos(c) - north * sin(c))
    }

    /// Chênh lệch hai hướng (độ, 0..180).
    public static func bearingDiff(_ a: Double, _ b: Double) -> Double {
        var d = abs((a - b).truncatingRemainder(dividingBy: 360))
        if d > 180 { d = 360 - d }
        return d
    }
}

public struct RememberedSign: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// Mã QCVN đưa vào luật (P.130, P.102...).
    public var code: String
    public var group: String
    public var lat: Double
    public var lon: Double
    /// Hướng xe đi khi thấy biển: biển chỉ dành cho chiều này.
    public var bearingDeg: Double
    /// Số lần camera xác nhận / số lần đi qua mà camera không thấy.
    public var seen: Int
    public var missed: Int
    public var lastSeen: Double
}

public struct SignMemory: Codable, Equatable, Sendable {
    public var signs: [RememberedSign] = []
    /// Hai lần thấy cùng mã cách nhau dưới mức này (m), cùng hướng đi: là một biển (GPS lệch 5–10 m).
    public var mergeM = 25.0
    public var bearingTolDeg = 45.0
    /// Nhắc biển đã nhớ khi còn cách tối đa ngần này (m) phía trước.
    public var lookAheadM = 80.0
    public var maxLateralM = 15.0
    /// Đi qua chỗ biển ngần này lần mà camera không thấy (và nhiều hơn số lần thấy) thì coi như biển đã bị gỡ.
    public var dropAfterMisses = 3

    public init() {}

    enum CodingKeys: String, CodingKey { case signs }

    /// Ghi nhận biển camera vừa xác nhận. Trả về biển trong bản đồ (mới hoặc đã gộp).
    @discardableResult
    public mutating func record(code: String, group: String, carLat: Double, carLon: Double, courseDeg: Double,
                                aheadM: Double, lateralM: Double, time: Double) -> RememberedSign {
        let p = Geo.offset(lat: carLat, lon: carLon, courseDeg: courseDeg, forwardM: aheadM, rightM: lateralM)
        if let i = nearest(code: code, lat: p.lat, lon: p.lon, bearing: courseDeg) {
            var s = signs[i]
            // trung bình có trọng số: càng nhiều lần thấy vị trí càng ổn định
            let w = Double(min(s.seen, 10))
            s.lat = (s.lat * w + p.lat) / (w + 1)
            s.lon = (s.lon * w + p.lon) / (w + 1)
            s.seen += 1
            s.missed = max(0, s.missed - 1)
            s.lastSeen = time
            signs[i] = s
            return s
        }
        let s = RememberedSign(id: "\(code)@\(Int(time))@\(signs.count)", code: code, group: group, lat: p.lat, lon: p.lon,
                               bearingDeg: courseDeg, seen: 1, missed: 0, lastSeen: time)
        signs.append(s)
        return s
    }

    func nearest(code: String, lat: Double, lon: Double, bearing: Double) -> Int? {
        var best: (i: Int, d: Double)?
        for (i, s) in signs.enumerated() where s.code == code && Geo.bearingDiff(s.bearingDeg, bearing) <= bearingTolDeg {
            let l = Geo.local(lat: lat, lon: lon, courseDeg: 0, toLat: s.lat, toLon: s.lon)
            let d = (l.forward * l.forward + l.right * l.right).squareRoot()
            if d <= mergeM, best == nil || d < best!.d { best = (i, d) }
        }
        return best?.i
    }

    /// Biển đã nhớ phía trước xe, cùng chiều đi: (biển, còn cách bao nhiêu mét).
    public func upcoming(lat: Double, lon: Double, courseDeg: Double) -> [(sign: RememberedSign, aheadM: Double)] {
        signs.compactMap { s in
            guard Geo.bearingDiff(s.bearingDeg, courseDeg) <= bearingTolDeg else { return nil }
            let l = Geo.local(lat: lat, lon: lon, courseDeg: courseDeg, toLat: s.lat, toLon: s.lon)
            guard l.forward > 0, l.forward <= lookAheadM, abs(l.right) <= maxLateralM else { return nil }
            return (s, l.forward)
        }
        .sorted { $0.aheadM < $1.aheadM }
    }

    public mutating func markMissed(id: String) {
        guard let i = signs.firstIndex(where: { $0.id == id }) else { return }
        signs[i].missed += 1
        if signs[i].missed >= dropAfterMisses && signs[i].missed > signs[i].seen { signs.remove(at: i) }
    }
}

/// Theo dõi trong một chuyến: biển nhớ nào sắp tới (nhắc một lần), camera có thấy lại không (thấy → cập nhật vị trí,
/// đi qua mà không thấy → đếm lần sót).
public struct SignRecall: Equatable, Sendable {
    public var memory: SignMemory
    /// Biển đã nhắc trong lần đi qua này: id → odometer chỗ cắm biển, camera đã thấy lại chưa.
    private var announced: [String: (atOdo: Double, confirmed: Bool)] = [:]
    /// Đi quá chỗ biển ngần này (m) thì chốt lần đi qua (thấy / sót).
    public var settleM = 40.0

    public init(memory: SignMemory = SignMemory()) { self.memory = memory }

    public static func == (a: SignRecall, b: SignRecall) -> Bool { a.memory == b.memory }

    /// Gọi mỗi frame có GPS. Trả về biển nhớ mới cần đưa vào luật (mỗi biển một lần mỗi lượt đi qua) và bản đồ có đổi
    /// không (để app lưu file). `cameraActive`: model dò biển đang chạy (chỉ khi đó mới tính là camera sót).
    public mutating func update(lat: Double, lon: Double, courseDeg: Double, odometer: Double, cameraActive: Bool)
        -> (due: [(sign: RememberedSign, aheadM: Double)], changed: Bool) {
        var changed = false
        for (id, a) in announced where odometer > a.atOdo + settleM {
            announced[id] = nil
            if !a.confirmed && cameraActive {
                memory.markMissed(id: id)
                changed = true
            }
        }
        var due: [(sign: RememberedSign, aheadM: Double)] = []
        for u in memory.upcoming(lat: lat, lon: lon, courseDeg: courseDeg) where announced[u.sign.id] == nil {
            announced[u.sign.id] = (odometer + u.aheadM, false)
            due.append(u)
        }
        return (due, changed)
    }

    /// Camera xác nhận biển dành cho làn mình: lưu / cập nhật bản đồ, đánh dấu lượt đi qua này đã thấy.
    @discardableResult
    public mutating func cameraSaw(code: String, group: String, carLat: Double, carLon: Double, courseDeg: Double,
                                   aheadM: Double, lateralM: Double, odometer: Double, time: Double) -> RememberedSign {
        let s = memory.record(code: code, group: group, carLat: carLat, carLon: carLon, courseDeg: courseDeg,
                              aheadM: aheadM, lateralM: lateralM, time: time)
        if let a = announced[s.id] {
            announced[s.id] = (a.atOdo, true)
        } else {
            announced[s.id] = (odometer + aheadM, true)   // đã ở gần: không nhắc lại từ bản đồ trong lượt này
        }
        return s
    }

    public mutating func clear() {
        memory.signs.removeAll()
        announced.removeAll()
    }
}

public extension SignEngine {
    /// Biển camera xác nhận có đáng nhớ vào bản đồ không: chỉ biển dành cho làn mình và đi thẳng qua là có hiệu lực
    /// (không nhớ biển đường nhánh / chiều ngược lại, chúng chỉ áp dụng khi rẽ).
    func isOwnRoadSign(_ c: ConfirmedSign) -> Bool {
        guard c.applies, let code = c.lawCode, let rule = config.signs[code] else { return false }
        return rule.scope != .entry || (c.lateralM ?? 0) <= Self.sideRoadLateralM
    }
}

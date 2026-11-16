// Dữ liệu đường OpenStreetMap (không vẽ bản đồ, chỉ lấy số làn / một chiều / tốc độ giới hạn của con đường đang chạy).
// App tải theo ô 0.05° × 0.05° (~5.5 km) từ Overpass API, lưu từng ô; mọi ô đã tải được gộp vào một RoadMap
// (bỏ trùng theo id của way), nên đường đi qua ranh giới hai ô vẫn liền mạch.
import Foundation

public struct RoadWay: Codable, Equatable, Sendable {
    public var id: Int64
    /// 0 motorway, 1 trunk, 2 primary, 3 secondary, 4 tertiary, 5 đường nhỏ (unclassified / residential), 6 nhánh nối (_link)
    public var cls: Int
    /// 1 = một chiều theo hướng vẽ, -1 = một chiều ngược hướng vẽ, 0 = hai chiều
    public var oneway: Int
    public var lanes: Int?
    public var lanesForward: Int?
    public var lanesBackward: Int?
    public var maxspeed: Int?
    public var lat: [Double]
    public var lon: [Double]

    public init(id: Int64, cls: Int, oneway: Int, lanes: Int? = nil, lanesForward: Int? = nil, lanesBackward: Int? = nil,
                maxspeed: Int? = nil, lat: [Double], lon: [Double]) {
        self.id = id; self.cls = cls; self.oneway = oneway; self.lanes = lanes
        self.lanesForward = lanesForward; self.lanesBackward = lanesBackward; self.maxspeed = maxspeed
        self.lat = lat; self.lon = lon
    }
}

/// Kết quả khớp vị trí xe với một con đường.
public struct RoadMatch: Equatable, Sendable {
    public var wayId: Int64
    public var cls: Int
    public var oneway: Bool
    /// Số làn cùng chiều xe mình / ngược chiều (nil = OSM không ghi).
    public var lanesSame: Int?
    public var lanesOpposite: Int?
    public var maxspeed: Int?
    /// Khoảng cách từ vị trí GPS tới tim đường (m).
    public var distanceM: Double
}

public enum OSMTile {
    public static let size = 0.05

    public struct Key: Hashable, Codable, Sendable, Comparable {
        public var lat: Int
        public var lon: Int
        public init(lat: Int, lon: Int) { self.lat = lat; self.lon = lon }
        public static func < (a: Key, b: Key) -> Bool { (a.lat, a.lon) < (b.lat, b.lon) }
        public var name: String { "\(lat)_\(lon)" }
        /// (nam, tây, bắc, đông)
        public var bbox: (s: Double, w: Double, n: Double, e: Double) {
            (Double(lat) * size, Double(lon) * size, Double(lat + 1) * size, Double(lon + 1) * size)
        }
    }

    public static func key(lat: Double, lon: Double) -> Key {
        Key(lat: Int(floor(lat / size + 1e-9)), lon: Int(floor(lon / size + 1e-9)))
    }

    /// Các ô phủ một vùng (nam, tây, bắc, đông).
    public static func keys(s: Double, w: Double, n: Double, e: Double) -> [Key] {
        let a = key(lat: s, lon: w), b = key(lat: n - 1e-9, lon: e - 1e-9)
        var out: [Key] = []
        for la in a.lat...b.lat { for lo in a.lon...b.lon { out.append(Key(lat: la, lon: lo)) } }
        return out
    }

    /// Ô chứa điểm và các ô xung quanh trong bán kính `ring` ô.
    public static func around(lat: Double, lon: Double, ring: Int = 1) -> [Key] {
        let c = key(lat: lat, lon: lon)
        var out: [Key] = []
        for dl in -ring...ring { for dn in -ring...ring { out.append(Key(lat: c.lat + dl, lon: c.lon + dn)) } }
        return out
    }

    public static let highwayClasses = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link"

    /// Câu truy vấn Overpass cho một ô: chỉ đường xe chạy, kèm tag và toạ độ.
    public static func overpassQuery(_ k: Key) -> String {
        let b = k.bbox
        return "[out:json][timeout:120];way[\"highway\"~\"^(\(highwayClasses))$\"](\(b.s),\(b.w),\(b.n),\(b.e));out tags geom;"
    }

    /// Đọc JSON trả về từ Overpass (`out tags geom`).
    public static func parseOverpass(_ data: Data) throws -> [RoadWay] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else {
            throw NSError(domain: "OSM", code: 1, userInfo: [NSLocalizedDescriptionKey: "JSON Overpass không hợp lệ"])
        }
        func int(_ s: String?) -> Int? {
            guard let s else { return nil }
            let digits = s.prefix { $0.isNumber }
            return Int(digits)
        }
        var out: [RoadWay] = []
        for e in elements where (e["type"] as? String) == "way" {
            guard let id = (e["id"] as? NSNumber)?.int64Value,
                  let tags = e["tags"] as? [String: String], let hw = tags["highway"],
                  let geom = e["geometry"] as? [[String: Any]], geom.count >= 2 else { continue }
            let cls: Int
            switch hw {
            case "motorway": cls = 0
            case "trunk": cls = 1
            case "primary": cls = 2
            case "secondary": cls = 3
            case "tertiary": cls = 4
            case _ where hw.hasSuffix("_link"): cls = 6
            default: cls = 5
            }
            var oneway = 0
            switch tags["oneway"] {
            case "yes", "1", "true": oneway = 1
            case "-1", "reverse": oneway = -1
            case "no", "false", "0": oneway = 0
            default:
                if hw == "motorway" || hw == "motorway_link" || tags["junction"] == "roundabout" { oneway = 1 }
            }
            let lat = geom.compactMap { ($0["lat"] as? NSNumber)?.doubleValue }
            let lon = geom.compactMap { ($0["lon"] as? NSNumber)?.doubleValue }
            guard lat.count == geom.count, lon.count == geom.count else { continue }
            out.append(RoadWay(id: id, cls: cls, oneway: oneway, lanes: int(tags["lanes"]),
                               lanesForward: int(tags["lanes:forward"]), lanesBackward: int(tags["lanes:backward"]),
                               maxspeed: int(tags["maxspeed"]), lat: lat, lon: lon))
        }
        return out
    }
}

public final class RoadMap {
    /// Ô lưới chỉ mục (độ). ~220 m.
    static let cell = 0.002
    struct CellKey: Hashable { var a: Int; var b: Int }

    public private(set) var ways: [Int64: RoadWay] = [:]
    private var index: [CellKey: [(id: Int64, seg: Int)]] = [:]

    public init() {}

    public var count: Int { ways.count }

    public func removeAll() {
        ways.removeAll()
        index.removeAll()
    }

    /// Thêm đường (từ một ô). Way đã có (ô khác cũng chứa) thì bỏ qua.
    public func add(_ list: [RoadWay]) {
        for w in list where ways[w.id] == nil {
            ways[w.id] = w
            for i in 0..<(w.lat.count - 1) {
                let a0 = Int(floor(min(w.lat[i], w.lat[i + 1]) / Self.cell)), a1 = Int(floor(max(w.lat[i], w.lat[i + 1]) / Self.cell))
                let b0 = Int(floor(min(w.lon[i], w.lon[i + 1]) / Self.cell)), b1 = Int(floor(max(w.lon[i], w.lon[i + 1]) / Self.cell))
                for a in a0...a1 { for b in b0...b1 { index[CellKey(a: a, b: b), default: []].append((w.id, i)) } }
            }
        }
    }

    /// Khớp vị trí GPS (và hướng đi, độ, 0 = bắc, theo chiều kim đồng hồ) với con đường gần nhất hợp hướng.
    public func match(lat: Double, lon: Double, courseDeg: Double?, maxDistanceM: Double = 20) -> RoadMatch? {
        let mPerLat = 111_320.0, mPerLon = 111_320.0 * cos(lat * .pi / 180)
        let ca = Int(floor(lat / Self.cell)), cb = Int(floor(lon / Self.cell))
        var best: (score: Double, dist: Double, way: RoadWay, along: Bool)?
        var seen = Set<String>()
        for a in (ca - 1)...(ca + 1) {
            for b in (cb - 1)...(cb + 1) {
                for (id, i) in index[CellKey(a: a, b: b)] ?? [] {
                    guard seen.insert("\(id):\(i)").inserted, let w = ways[id] else { continue }
                    // toạ độ phẳng cục bộ (m), gốc ở vị trí xe
                    let ax = (w.lon[i] - lon) * mPerLon, ay = (w.lat[i] - lat) * mPerLat
                    let bx = (w.lon[i + 1] - lon) * mPerLon, by = (w.lat[i + 1] - lat) * mPerLat
                    let dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy
                    guard len2 > 0.01 else { continue }
                    let t = max(0, min(1, -(ax * dx + ay * dy) / len2))
                    let px = ax + t * dx, py = ay + t * dy
                    let dist = (px * px + py * py).squareRoot()
                    guard dist <= maxDistanceM else { continue }
                    var along = true, penalty = 0.0
                    if let c = courseDeg {
                        let segBearing = atan2(dx, dy) * 180 / .pi   // 0 = bắc
                        var diff = abs((c - segBearing).truncatingRemainder(dividingBy: 360))
                        if diff > 180 { diff = 360 - diff }
                        if diff <= 50 { along = true; penalty = diff / 10 }
                        else if diff >= 130 { along = false; penalty = (180 - diff) / 10 }
                        else { continue }   // đi cắt ngang: không phải đường này
                        if w.oneway == 1 && !along { continue }
                        if w.oneway == -1 && along { continue }
                    }
                    let score = dist + penalty
                    if best == nil || score < best!.score { best = (score, dist, w, along) }
                }
            }
        }
        guard let b = best else { return nil }
        let w = b.way
        if w.oneway != 0 {
            return RoadMatch(wayId: w.id, cls: w.cls, oneway: true, lanesSame: w.lanes, lanesOpposite: 0,
                             maxspeed: w.maxspeed, distanceM: b.dist)
        }
        let fwd = w.lanesForward ?? w.lanes.map { $0 / 2 }
        let bwd = w.lanesBackward ?? w.lanes.map { $0 - $0 / 2 }
        return RoadMatch(wayId: w.id, cls: w.cls, oneway: false,
                         lanesSame: (b.along ? fwd : bwd).flatMap { $0 > 0 ? $0 : nil },
                         lanesOpposite: (b.along ? bwd : fwd).flatMap { $0 > 0 ? $0 : nil },
                         maxspeed: w.maxspeed, distanceM: b.dist)
    }
}

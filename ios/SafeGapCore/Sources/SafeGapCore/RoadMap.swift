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
    /// Tên đường (name:vi, name) hoặc số hiệu (ref, ví dụ "QL1A"). Ô tải trước khi có trường này: nil.
    public var name: String?
    public var lat: [Double]
    public var lon: [Double]

    public init(id: Int64, cls: Int, oneway: Int, lanes: Int? = nil, lanesForward: Int? = nil, lanesBackward: Int? = nil,
                maxspeed: Int? = nil, name: String? = nil, lat: [Double], lon: [Double]) {
        self.id = id; self.cls = cls; self.oneway = oneway; self.lanes = lanes
        self.lanesForward = lanesForward; self.lanesBackward = lanesBackward; self.maxspeed = maxspeed
        self.name = name; self.lat = lat; self.lon = lon
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
    public var name: String? = nil
    /// Xe nằm bên phải tim đường bao nhiêu mét (theo chiều xe đi; âm = bên trái). GPS lệch 5–10 m.
    public var rightOfCenterM: Double = 0
    public static let laneWidthM = 3.5

    /// Từ xe tới mép phải đường (m) theo số làn OSM; nil nếu OSM không ghi số làn.
    public var rightEdgeGapM: Double? {
        let w = Self.laneWidthM
        // đường một chiều: tim đường ở giữa; hai chiều: tim đường là vạch giữa hai chiều
        let edge: Double? = oneway ? lanesSame.map { Double($0) * w / 2 } : lanesSame.map { Double($0) * w }
        return edge.map { $0 - rightOfCenterM }
    }
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

    static func roadName(_ tags: [String: String]) -> String? {
        let n = [tags["name:vi"], tags["name"]].compactMap { $0 }.first { !$0.isEmpty }
        let ref = tags["ref"].flatMap { $0.isEmpty ? nil : $0 }
        if let n, let ref, !n.contains(ref) { return "\(n) (\(ref))" }
        return n ?? ref
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
                               maxspeed: int(tags["maxspeed"]), name: roadName(tags), lat: lat, lon: lon))
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
    /// Nút chung giữa các way (OSM dùng chung nút ở chỗ nối nên toạ độ trùng hệt): toạ độ ×1e7 → (way, chỉ số nút).
    struct NodeKey: Hashable { var a: Int32; var b: Int32 }
    private var nodes: [NodeKey: [(id: Int64, idx: Int)]] = [:]
    static func nodeKey(_ lat: Double, _ lon: Double) -> NodeKey {
        NodeKey(a: Int32((lat * 1e7).rounded()), b: Int32((lon * 1e7).rounded()))
    }

    public init() {}

    public var count: Int { ways.count }

    public func removeAll() {
        ways.removeAll()
        index.removeAll()
        nodes.removeAll()
    }

    /// Thêm đường (từ một ô). Way đã có (ô khác cũng chứa) thì bỏ qua, chỉ bổ sung tên nếu bản cũ chưa có.
    public func add(_ list: [RoadWay]) {
        for w in list {
            if let old = ways[w.id] {
                if old.name == nil, let n = w.name { ways[w.id]?.name = n }
                continue
            }
            ways[w.id] = w
            for i in 0..<(w.lat.count - 1) {
                let a0 = Int(floor(min(w.lat[i], w.lat[i + 1]) / Self.cell)), a1 = Int(floor(max(w.lat[i], w.lat[i + 1]) / Self.cell))
                let b0 = Int(floor(min(w.lon[i], w.lon[i + 1]) / Self.cell)), b1 = Int(floor(max(w.lon[i], w.lon[i + 1]) / Self.cell))
                for a in a0...a1 { for b in b0...b1 { index[CellKey(a: a, b: b), default: []].append((w.id, i)) } }
            }
            for i in 0..<w.lat.count { nodes[Self.nodeKey(w.lat[i], w.lon[i]), default: []].append((w.id, i)) }
        }
    }

    /// Khớp vị trí GPS (và hướng đi, độ, 0 = bắc, theo chiều kim đồng hồ) với con đường gần nhất hợp hướng.
    public func match(lat: Double, lon: Double, courseDeg: Double?, maxDistanceM: Double = 20) -> RoadMatch? {
        guard let b = locate(lat: lat, lon: lon, courseDeg: courseDeg, maxDistanceM: maxDistanceM) else { return nil }
        let w = b.way
        if w.oneway != 0 {
            return RoadMatch(wayId: w.id, cls: w.cls, oneway: true, lanesSame: w.lanes, lanesOpposite: 0,
                             maxspeed: w.maxspeed, distanceM: b.dist, name: w.name, rightOfCenterM: b.right)
        }
        let fwd = w.lanesForward ?? w.lanes.map { $0 / 2 }
        let bwd = w.lanesBackward ?? w.lanes.map { $0 - $0 / 2 }
        return RoadMatch(wayId: w.id, cls: w.cls, oneway: false,
                         lanesSame: (b.along ? fwd : bwd).flatMap { $0 > 0 ? $0 : nil },
                         lanesOpposite: (b.along ? bwd : fwd).flatMap { $0 > 0 ? $0 : nil },
                         maxspeed: w.maxspeed, distanceM: b.dist, name: w.name, rightOfCenterM: b.right)
    }

    struct Located {
        var dist: Double; var way: RoadWay; var seg: Int; var t: Double; var along: Bool
        /// Xe bên phải tim đường (m) theo chiều đi.
        var right: Double = 0
    }

    func locate(lat: Double, lon: Double, courseDeg: Double?, maxDistanceM: Double) -> Located? {
        let mPerLat = 111_320.0, mPerLon = 111_320.0 * cos(lat * .pi / 180)
        let ca = Int(floor(lat / Self.cell)), cb = Int(floor(lon / Self.cell))
        var best: (score: Double, loc: Located)?
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
                    // xe so với điểm gần nhất trên tim đường: (-px, -py); bên phải của hướng đi (fx, fy) là (fy, -fx)
                    let l = len2.squareRoot(), s = along ? 1.0 : -1.0
                    let fx = s * dx / l, fy = s * dy / l
                    let right = -px * fy + -py * -fx
                    if best == nil || score < best!.score {
                        best = (score, Located(dist: dist, way: w, seg: i, t: t, along: along, right: right))
                    }
                }
            }
        }
        return best?.loc
    }

    /// Hình dạng con đường phía trước xe (đi theo way đang khớp, tới cuối way thì nối sang way chung nút
    /// rẽ ít nhất, ≤ 60°) và các ngã tư/ngã ba trên đường đi (nút có ≥ 3 nhánh).
    public func ahead(lat: Double, lon: Double, courseDeg: Double?, maxDistanceM: Double = 20,
                      length: Double = 300) -> RoadAhead? {
        guard let loc = locate(lat: lat, lon: lon, courseDeg: courseDeg, maxDistanceM: maxDistanceM) else { return nil }
        let mPerLat = 111_320.0, mPerLon = 111_320.0 * cos(lat * .pi / 180)
        func xy(_ w: RoadWay, _ i: Int) -> (Double, Double) { ((w.lon[i] - lon) * mPerLon, (w.lat[i] - lat) * mPerLat) }
        let w0 = loc.way
        let a = xy(w0, loc.seg), b = xy(w0, loc.seg + 1)
        let p0 = (a.0 + loc.t * (b.0 - a.0), a.1 + loc.t * (b.1 - a.1))
        // hướng đi dọc đoạn đường (đông, bắc) và hướng sang phải
        var fx = b.0 - a.0, fy = b.1 - a.1
        if !loc.along { fx = -fx; fy = -fy }
        let fl = (fx * fx + fy * fy).squareRoot()
        fx /= fl; fy /= fl
        let rx = fy, ry = -fx
        func local(_ p: (Double, Double)) -> RoadPoint {
            let dx = p.0 - p0.0, dy = p.1 - p0.1
            return RoadPoint(x: dx * rx + dy * ry, z: dx * fx + dy * fy)
        }
        func branches(_ w: RoadWay, _ i: Int) -> Int {
            var seen = Set<Int64>(), n = 0
            for (id, idx) in nodes[Self.nodeKey(w.lat[i], w.lon[i])] ?? [] {
                guard let ww = ways[id] else { continue }
                if seen.contains(id) { continue }   // way khép kín lặp lại nút đầu
                seen.insert(id)
                n += (idx == 0 || idx == ww.lat.count - 1) && ww.lat.first != ww.lat.last ? 1 : 2
            }
            return n
        }

        var path = [RoadPoint(x: 0, z: 0)]
        var junctions: [Double] = []
        var way = w0
        var idx = loc.along ? loc.seg + 1 : loc.seg
        var step = loc.along ? 1 : -1
        var visited: Set<Int64> = [w0.id]
        var travelled = 0.0
        var lastBearing = atan2(fx, fy)
        var prev = p0
        for _ in 0..<2000 {
            let p = xy(way, idx)
            let seg = ((p.0 - prev.0) * (p.0 - prev.0) + (p.1 - prev.1) * (p.1 - prev.1)).squareRoot()
            if seg > 0.01 {
                travelled += seg
                let lp = local(p)
                guard lp.z > path.last!.z else { break }   // đường quay ngược (vòng gắt): dừng
                path.append(lp)
                lastBearing = atan2(p.0 - prev.0, p.1 - prev.1)
                prev = p
            }
            if branches(way, idx) >= 3, let z = path.last?.z, z > 0 { junctions.append(z) }
            if travelled >= length { break }
            let nextIdx = idx + step
            if nextIdx >= 0 && nextIdx < way.lat.count { idx = nextIdx; continue }
            // hết way: nối sang way khác chung nút, rẽ ít nhất
            var bestNext: (turn: Double, way: RoadWay, idx: Int, step: Int)?
            for (id, j) in nodes[Self.nodeKey(way.lat[idx], way.lon[idx])] ?? [] where !visited.contains(id) {
                guard let ww = ways[id] else { continue }
                for st in [1, -1] {
                    let k = j + st
                    guard k >= 0, k < ww.lat.count else { continue }
                    if ww.oneway == 1 && st == -1 { continue }
                    if ww.oneway == -1 && st == 1 { continue }
                    let q = xy(ww, k), c = xy(ww, j)
                    var turn = abs(atan2(q.0 - c.0, q.1 - c.1) - lastBearing)
                    if turn > .pi { turn = 2 * .pi - turn }
                    if turn <= .pi / 3, bestNext == nil || turn < bestNext!.turn { bestNext = (turn, ww, k, st) }
                }
            }
            guard let n = bestNext else { break }
            visited.insert(n.way.id)
            way = n.way; idx = n.idx; step = n.step
        }
        // ngã tư đường đôi (hai nhánh cách nhau vài mét) chỉ tính một
        var merged: [Double] = []
        for z in junctions.sorted() where merged.last.map({ z - $0 > 15 }) ?? true { merged.append(z) }
        return RoadAhead(path: path, junctions: merged)
    }
}

public struct RoadPoint: Equatable, Sendable {
    public var x: Double
    public var z: Double
    public init(x: Double, z: Double) { self.x = x; self.z = z }
}

/// Đường phía trước theo hệ toạ độ gắn với tim đường tại chỗ xe: z dọc đường (m, phía trước), x sang phải (m).
public struct RoadAhead: Equatable, Sendable {
    public var path: [RoadPoint]
    /// Khoảng cách (m) tới các ngã tư / ngã ba phía trước, tăng dần.
    public var junctions: [Double]
    public init(path: [RoadPoint], junctions: [Double]) { self.path = path; self.junctions = junctions }

    public var length: Double { path.last?.z ?? 0 }

    /// x của tim đường tại z (nội suy), nil nếu ngoài đoạn đã biết.
    public func x(at z: Double) -> Double? {
        guard path.count > 1, z >= path[0].z, z <= path[path.count - 1].z else { return nil }
        for i in 1..<path.count where path[i].z >= z {
            let a = path[i - 1], b = path[i]
            return b.z == a.z ? a.x : a.x + (z - a.z) * (b.x - a.x) / (b.z - a.z)
        }
        return path.last?.x
    }

    /// Phần cong thêm của đường so với đường thẳng tiếp tuyến tại `join`: 0 khi z ≤ join, liền mạch (cả độ dốc) tại join.
    /// Màn lái cộng phần này vào làn camera ở đoạn xa.
    public func bend(at z: Double, join: Double) -> Double {
        guard z > join, let x0 = x(at: join) else { return 0 }
        let h = 5.0
        let xa = x(at: max(join - h, path.first?.z ?? 0)) ?? x0, xb = x(at: join + h) ?? x0
        let slope = (xb - xa) / (min(join + h, length) - max(join - h, path.first?.z ?? 0))
        let zc = min(z, length)
        let xz = x(at: zc) ?? x0
        // ngoài đoạn đã biết: kéo thẳng theo hướng cuối
        var extra = 0.0
        if z > length, path.count > 1 {
            let a = path[path.count - 2], b = path[path.count - 1]
            extra = b.z > a.z ? (z - length) * (b.x - a.x) / (b.z - a.z) : 0
        }
        return xz + extra - x0 - slope * (z - join)
    }

    /// Dịch theo quãng đường xe đã đi từ lúc tra (giữa hai lần tra mỗi giây).
    public func advanced(by d: Double) -> RoadAhead {
        guard d != 0 else { return self }
        return RoadAhead(path: path.map { RoadPoint(x: $0.x, z: $0.z - d) },
                         junctions: junctions.map { $0 - d }.filter { $0 > -10 })
    }
}

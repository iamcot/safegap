import XCTest
@testable import SafeGapCore

final class RoadAheadTests: XCTestCase {
    let lat0 = 10.77, lon0 = 106.70
    var mLat: Double { 1 / 111_320.0 }
    var mLon: Double { 1 / (111_320.0 * cos(lat0 * .pi / 180)) }
    func ll(_ east: Double, _ north: Double) -> (Double, Double) { (lat0 + north * mLat, lon0 + east * mLon) }
    func way(_ id: Int64, _ pts: [(Double, Double)], oneway: Int = 0) -> RoadWay {
        let p = pts.map { ll($0.0, $0.1) }
        return RoadWay(id: id, cls: 2, oneway: oneway, lat: p.map(\.0), lon: p.map(\.1))
    }

    /// Đường đi bắc 200 m (way 10), sau đó rẽ phải 30° thêm 150 m (way 11, nối liền, không phải ngã tư);
    /// đường ngang đông–tây (way 12) cắt qua ở 100 m.
    func map() -> RoadMap {
        let m = RoadMap()
        let s = sin(Double.pi / 6), c = cos(Double.pi / 6)
        m.add([
            way(10, [(0, 0), (0, 50), (0, 100), (0, 150), (0, 200)]),
            way(11, [(0, 200), (50 * s, 200 + 50 * c), (100 * s, 200 + 100 * c), (150 * s, 200 + 150 * c)]),
            way(12, [(-100, 100), (0, 100), (100, 100)]),
        ])
        return m
    }

    func testJunctionAndCurveAhead() throws {
        let p = ll(0, 10)
        let a = try XCTUnwrap(map().ahead(lat: p.0, lon: p.1, courseDeg: 0))
        XCTAssertEqual(a.junctions.count, 1)            // chỗ nối way 10 → 11 có 2 nhánh: không phải ngã tư
        XCTAssertEqual(a.junctions[0], 90, accuracy: 2)
        XCTAssertEqual(a.x(at: 150)!, 0, accuracy: 0.5)
        XCTAssertGreaterThan(a.x(at: 300)!, 40)          // rẽ phải 30°: ~110 m × tan... lệch phải rõ
        XCTAssertGreaterThan(a.length, 300)
    }

    func testAheadGoingSouth() throws {
        let p = ll(0, 150)
        let a = try XCTUnwrap(map().ahead(lat: p.0, lon: p.1, courseDeg: 180))
        XCTAssertEqual(a.junctions.count, 1)
        XCTAssertEqual(a.junctions[0], 50, accuracy: 2)
        XCTAssertEqual(a.length, 150, accuracy: 2)       // hết way ở đầu nam, không nối tiếp
        XCTAssertEqual(a.x(at: 100)!, 0, accuracy: 0.5)
    }

    func testBendIsSmoothAndZeroBeforeJoin() {
        let straight = RoadAhead(path: [RoadPoint(x: 0, z: 0), RoadPoint(x: 0, z: 300)], junctions: [])
        XCTAssertEqual(straight.bend(at: 200, join: 40), 0, accuracy: 1e-9)
        // tim đường lệch phải dần: x = z²/1000
        let pts = stride(from: 0.0, through: 300, by: 10).map { RoadPoint(x: $0 * $0 / 1000, z: $0) }
        let curved = RoadAhead(path: pts, junctions: [])
        XCTAssertEqual(curved.bend(at: 30, join: 40), 0)
        XCTAssertEqual(curved.bend(at: 41, join: 40), 0, accuracy: 0.05)
        // (z−40)²/1000 ở 140 m = 10 m
        XCTAssertEqual(curved.bend(at: 140, join: 40), 10, accuracy: 0.3)
    }

    func testAdvanced() {
        let a = RoadAhead(path: [RoadPoint(x: 0, z: 0), RoadPoint(x: 1, z: 100)], junctions: [5, 60])
        let b = a.advanced(by: 20)
        XCTAssertEqual(b.junctions, [40])
        XCTAssertEqual(b.path[1].z, 80)
    }
}

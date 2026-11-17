import XCTest
@testable import SafeGapCore

final class RoadMapTests: XCTestCase {
    // Đường hai chiều chạy hướng bắc (vẽ từ nam lên bắc), 6 làn: 4 chiều đi, 2 chiều về; và đường một chiều hướng đông.
    let json = """
    {"elements":[
     {"type":"way","id":1,"tags":{"highway":"primary","name":"Nguyễn Huệ","lanes":"6","lanes:forward":"4","lanes:backward":"2","maxspeed":"60"},
      "geometry":[{"lat":10.7700,"lon":106.7000},{"lat":10.7750,"lon":106.7000},{"lat":10.7800,"lon":106.7000}]},
     {"type":"way","id":2,"tags":{"highway":"secondary","oneway":"yes","lanes":"3","name":"Quốc lộ 1A","ref":"QL1A"},
      "geometry":[{"lat":10.7900,"lon":106.7100},{"lat":10.7900,"lon":106.7200}]},
     {"type":"way","id":3,"tags":{"highway":"tertiary","lanes":"4","ref":"ĐT743"},
      "geometry":[{"lat":10.8000,"lon":106.7300},{"lat":10.8050,"lon":106.7300}]},
     {"type":"node","id":9,"lat":1,"lon":2}
    ]}
    """.data(using: .utf8)!

    func map() throws -> RoadMap {
        let m = RoadMap()
        m.add(try OSMTile.parseOverpass(json))
        return m
    }

    func testParse() throws {
        let w = try OSMTile.parseOverpass(json)
        XCTAssertEqual(w.count, 3)
        XCTAssertEqual(w[0].cls, 2)
        XCTAssertEqual(w[0].maxspeed, 60)
        XCTAssertEqual(w[1].oneway, 1)
        XCTAssertEqual(w.map(\.name), ["Nguyễn Huệ", "Quốc lộ 1A (QL1A)", "ĐT743"])
    }

    func testRoadNameInMatchAndOldTilesGetNames() throws {
        XCTAssertEqual(try map().match(lat: 10.7740, lon: 106.70005, courseDeg: 2)?.name, "Nguyễn Huệ")
        // ô lưu từ bản cũ (không có tên), sau đó tải lại ô: tên được bổ sung
        let m = RoadMap()
        let w = try OSMTile.parseOverpass(json)
        let old = try JSONDecoder().decode([RoadWay].self, from: JSONEncoder().encode(w.map { var x = $0; x.name = nil; return x }))
        m.add(old)
        XCTAssertNil(m.match(lat: 10.7740, lon: 106.70005, courseDeg: 2)?.name)
        m.add(w)
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(m.match(lat: 10.7740, lon: 106.70005, courseDeg: 2)?.name, "Nguyễn Huệ")
    }

    func testMatchAlongAndAgainst() throws {
        let m = try map()
        // cách tim đường ~5 m về phía đông, đi hướng bắc: cùng hướng vẽ
        let north = m.match(lat: 10.7740, lon: 106.70005, courseDeg: 2)!
        XCTAssertEqual(north.wayId, 1)
        XCTAssertEqual(north.lanesSame, 4)
        XCTAssertEqual(north.lanesOpposite, 2)
        XCTAssertEqual(north.maxspeed, 60)
        XCTAssertLessThan(north.distanceM, 8)
        // đi hướng nam: ngược hướng vẽ
        let south = m.match(lat: 10.7740, lon: 106.69995, courseDeg: 181)!
        XCTAssertEqual(south.lanesSame, 2)
        XCTAssertEqual(south.lanesOpposite, 4)
    }

    func testCrossingAndFarAreRejected() throws {
        let m = try map()
        XCTAssertNil(m.match(lat: 10.7740, lon: 106.70005, courseDeg: 90))   // đi cắt ngang
        XCTAssertNil(m.match(lat: 10.7740, lon: 106.7010, courseDeg: 0))     // xa ~110 m
    }

    func testOnewayAndSplitLanes() throws {
        let m = try map()
        let e = m.match(lat: 10.79005, lon: 106.7150, courseDeg: 88)!
        XCTAssertTrue(e.oneway)
        XCTAssertEqual(e.lanesSame, 3)
        XCTAssertEqual(e.lanesOpposite, 0)
        XCTAssertNil(m.match(lat: 10.79005, lon: 106.7150, courseDeg: 270))   // ngược chiều đường một chiều
        let t = m.match(lat: 10.8020, lon: 106.7300, courseDeg: 0)!
        XCTAssertEqual(t.lanesSame, 2)
        XCTAssertEqual(t.lanesOpposite, 2)
    }

    func testMergeTilesDedupes() throws {
        let m = RoadMap()
        let w = try OSMTile.parseOverpass(json)
        m.add(w)
        m.add(w)   // ô bên cạnh cũng chứa cùng way
        XCTAssertEqual(m.count, 3)
        XCTAssertNotNil(m.match(lat: 10.7740, lon: 106.70005, courseDeg: nil))
    }

    func testTiles() {
        let k = OSMTile.key(lat: 10.7769, lon: 106.7009)
        XCTAssertEqual(k, OSMTile.Key(lat: 215, lon: 2134))
        XCTAssertEqual(OSMTile.around(lat: 10.7769, lon: 106.7009).count, 9)
        XCTAssertEqual(OSMTile.keys(s: 10.65, w: 106.55, n: 10.95, e: 106.85).count, 36)
        XCTAssertTrue(OSMTile.overpassQuery(k).contains("(10.75,106.7,10.8,106.75)"))
    }
}

@testable import SafeGapCore
import XCTest

final class SignMapTests: XCTestCase {
    // Sài Gòn, đi hướng đông (90°)
    let lat0 = 10.7769, lon0 = 106.7009

    func testGeoOffsetRoundTrip() {
        let p = Geo.offset(lat: lat0, lon: lon0, courseDeg: 90, forwardM: 30, rightM: 4)
        let l = Geo.local(lat: lat0, lon: lon0, courseDeg: 90, toLat: p.lat, toLon: p.lon)
        XCTAssertEqual(l.forward, 30, accuracy: 0.01)
        XCTAssertEqual(l.right, 4, accuracy: 0.01)
        // đi hướng đông thì bên phải là phía nam
        XCTAssertLessThan(p.lat, lat0)
        XCTAssertEqual(Geo.bearingDiff(350, 10), 20, accuracy: 1e-9)
    }

    func testRecordMergesNearbySightingsAndRecallsAhead() {
        var m = SignMemory()
        m.record(code: "P.130", group: "no_stop_park", carLat: lat0, carLon: lon0, courseDeg: 90, aheadM: 30, lateralM: 4, time: 1)
        // lần sau thấy lại lệch 8 m (GPS), cùng hướng: một biển
        let start = Geo.offset(lat: lat0, lon: lon0, courseDeg: 90, forwardM: 8, rightM: 0)
        let s = m.record(code: "P.130", group: "no_stop_park", carLat: start.lat, carLon: start.lon, courseDeg: 92,
                         aheadM: 30, lateralM: 4, time: 2)
        XCTAssertEqual(m.signs.count, 1)
        XCTAssertEqual(s.seen, 2)
        // đi ngược chiều cùng chỗ: biển khác
        m.record(code: "P.130", group: "no_stop_park", carLat: lat0, carLon: lon0, courseDeg: 270, aheadM: 30, lateralM: 4, time: 3)
        XCTAssertEqual(m.signs.count, 2)
        // đang cách biển ~60 m, đi hướng đông: chỉ biển chiều đông được nhắc
        let back = Geo.offset(lat: lat0, lon: lon0, courseDeg: 90, forwardM: -25, rightM: 0)
        let up = m.upcoming(lat: back.lat, lon: back.lon, courseDeg: 90)
        XCTAssertEqual(up.count, 1)
        XCTAssertEqual(up.first?.aheadM ?? 0, 59, accuracy: 3)
    }

    func testRecallOncePerPassAndDropsRemovedSign() {
        var r = SignRecall()
        r.memory.record(code: "P.130", group: "no_stop_park", carLat: lat0, carLon: lon0, courseDeg: 90, aheadM: 50, lateralM: 4, time: 0)
        var announced = 0
        // 3 lượt đi qua, camera không thấy biển (đã bị gỡ)
        for pass in 0..<3 {
            for step in 0...20 {
                let d = Double(step) * 5
                let p = Geo.offset(lat: lat0, lon: lon0, courseDeg: 90, forwardM: d, rightM: 0)
                let u = r.update(lat: p.lat, lon: p.lon, courseDeg: 90, odometer: Double(pass) * 1000 + d, cameraActive: true)
                announced += u.due.count
            }
        }
        XCTAssertEqual(announced, 3)       // lượt nào cũng nhắc; sau lượt 3 sót 3 lần > thấy 1 lần → xoá
        XCTAssertTrue(r.memory.signs.isEmpty)
    }

    func testCameraConfirmationKeepsSign() {
        var r = SignRecall()
        r.memory.record(code: "P.102", group: "no_entry", carLat: lat0, carLon: lon0, courseDeg: 90, aheadM: 50, lateralM: 3, time: 0)
        for pass in 0..<4 {
            for step in 0...20 {
                let d = Double(step) * 5
                let odo = Double(pass) * 1000 + d
                let p = Geo.offset(lat: lat0, lon: lon0, courseDeg: 90, forwardM: d, rightM: 0)
                _ = r.update(lat: p.lat, lon: p.lon, courseDeg: 90, odometer: odo, cameraActive: true)
                if step == 5 {   // camera thấy biển khi còn cách 25 m
                    r.cameraSaw(code: "P.102", group: "no_entry", carLat: p.lat, carLon: p.lon, courseDeg: 90,
                                aheadM: 25, lateralM: 3, odometer: odo, time: Double(pass))
                }
            }
        }
        XCTAssertEqual(r.memory.signs.count, 1)
        XCTAssertEqual(r.memory.signs.first?.seen, 5)
        XCTAssertEqual(r.memory.signs.first?.missed, 0)
    }

    func testMemoryCodableKeepsOnlySigns() throws {
        var m = SignMemory()
        m.record(code: "P.130", group: "no_stop_park", carLat: lat0, carLon: lon0, courseDeg: 90, aheadM: 30, lateralM: 4, time: 1)
        let back = try JSONDecoder().decode(SignMemory.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
    }

    func testOSMSpeedLimitUsedWhenSignHasNoNumber() throws {
        var e = SignEngine(config: try SignTests.repoConfig())
        // không có biển: theo maxspeed của đường
        _ = e.update(DriveContext(t: 0, odometer: 0, speedKmh: 70, mapSpeedLimitKmh: 60))
        XCTAssertEqual(e.update(DriveContext(t: 4, odometer: 80, speedKmh: 70, mapSpeedLimitKmh: 60)).map(\.text),
                       ["Quá tốc độ, đường này giới hạn 60"])
        // biển tốc độ từ model (chưa có số): lấy số trên OSM
        var e2 = SignEngine(config: try SignTests.repoConfig())
        _ = e2.sighted(SignSighting(code: "P.127"), odometer: 0, t: 0, minuteOfDay: 600, dayOfMonth: 1)
        _ = e2.update(DriveContext(t: 0, odometer: 10, speedKmh: 58, mapSpeedLimitKmh: 50))
        XCTAssertEqual(e2.update(DriveContext(t: 4, odometer: 70, speedKmh: 58, mapSpeedLimitKmh: 50)).map(\.text),
                       ["Quá tốc độ, giới hạn 50"])
    }
}

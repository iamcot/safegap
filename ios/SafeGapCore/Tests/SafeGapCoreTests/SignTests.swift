import XCTest
@testable import SafeGapCore

final class SignTests: XCTestCase {
    /// Đọc đúng file config/signs_vn.json của repo (cùng file app dùng).
    static func repoConfig() throws -> SignConfig {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // ios/SafeGapCore
            .deletingLastPathComponent().deletingLastPathComponent()                              // repo
            .appendingPathComponent("config/signs_vn.json")
        return try SignConfig.decode(Data(contentsOf: url))
    }

    func engine() throws -> SignEngine { SignEngine(config: try Self.repoConfig()) }

    func testRepoConfigParses() throws {
        let c = try Self.repoConfig()
        XCTAssertEqual(c.signs["P.130"]?.scope, .untilJunction)
        XCTAssertEqual(c.signs["P.123a"]?.forbidTurns, [.left])
        XCTAssertEqual(c.signs["DP.135"]?.ends, ["*"])
        XCTAssertEqual(c.alerts.noStopAfterS, 3)
    }

    func testNoStopZoneUntilJunction() throws {
        var e = try engine()
        XCTAssertTrue(e.sighted(SignSighting(code: "P.130"), odometer: 100, t: 0, minuteOfDay: 600, dayOfMonth: 1).isEmpty)
        // đứng 2 s: chưa
        XCTAssertTrue(e.update(DriveContext(t: 10, odometer: 150, stoppedS: 2, junctionM: 120)).isEmpty)
        // đứng 4 s, không phải kẹt xe / đèn đỏ: cảnh báo
        XCTAssertEqual(e.update(DriveContext(t: 12, odometer: 150, stoppedS: 4, junctionM: 120)).map(\.text),
                       ["Đang trong đoạn cấm dừng đỗ"])
        // kẹt xe: không
        XCTAssertTrue(e.update(DriveContext(t: 13, odometer: 150, stoppedS: 5, stopExcused: true, junctionM: 120)).isEmpty)
        // qua ngã tư: hết hiệu lực
        _ = e.update(DriveContext(t: 30, odometer: 280, junctionPassed: true))
        XCTAssertTrue(e.active.isEmpty)
    }

    func testJunctionRightBehindSignDoesNotClear() throws {
        var e = try engine()
        _ = e.sighted(SignSighting(code: "P.130"), odometer: 100, t: 0, minuteOfDay: 600, dayOfMonth: 1)
        _ = e.update(DriveContext(t: 1, odometer: 105, junctionPassed: true))
        XCTAssertEqual(e.active.map(\.code), ["P.130"])
    }

    func testNoLeftTurnReminderAndWarning() throws {
        var e = try engine()
        _ = e.sighted(SignSighting(code: "P.123a"), odometer: 0, t: 0, minuteOfDay: 600, dayOfMonth: 1)
        XCTAssertTrue(e.update(DriveContext(t: 1, odometer: 10, speedKmh: 30, junctionM: 150)).isEmpty)
        let remind = e.update(DriveContext(t: 5, odometer: 90, speedKmh: 30, junctionM: 70))
        XCTAssertEqual(remind.map(\.kind), [.signReminder])
        XCTAssertEqual(remind.first?.text, "Ngã tư phía trước cấm rẽ trái")
        let warn = e.update(DriveContext(t: 8, odometer: 140, speedKmh: 15, junctionM: 20, turning: .left))
        XCTAssertEqual(warn.map(\.text), ["Cấm rẽ trái!"])
        // rẽ phải thì không sao
        XCTAssertTrue(e.update(DriveContext(t: 8, odometer: 140, speedKmh: 15, junctionM: 20, turning: .right)).isEmpty)
        // đi thẳng qua ngã tư: hết hiệu lực
        _ = e.update(DriveContext(t: 12, odometer: 170, speedKmh: 30, junctionPassed: true))
        XCTAssertTrue(e.active.isEmpty)
    }

    func testNoUturnAlsoWarnsOnLeftStart() throws {
        var e = try engine()
        _ = e.sighted(SignSighting(code: "P.124a"), odometer: 0, t: 0, minuteOfDay: 600, dayOfMonth: 1)
        XCTAssertEqual(e.update(DriveContext(t: 3, odometer: 50, junctionM: 10, turning: .left)).map(\.text), ["Cấm quay đầu!"])
    }

    func testCarBanByTimeWindow() throws {
        var e = try engine()
        let w = TimeWindow(fromHour: 6, toHour: 22)
        let msgs = e.sighted(SignSighting(code: "P.103a", window: w), odometer: 0, t: 0, minuteOfDay: 7 * 60 + 15, dayOfMonth: 1)
        XCTAssertEqual(msgs.map(\.text), ["Đường cấm ô tô 6h–22h"])
        var e2 = try engine()
        XCTAssertTrue(e2.sighted(SignSighting(code: "P.103a", window: w), odometer: 0, t: 0, minuteOfDay: 23 * 60, dayOfMonth: 1).isEmpty)
        XCTAssertEqual(e2.active.first?.applies, false)
        // xe tải: biển cấm xe tải không áp dụng cho xe con
        var e3 = try engine()
        XCTAssertTrue(e3.sighted(SignSighting(code: "P.106a"), odometer: 0, t: 0, minuteOfDay: 600, dayOfMonth: 1).isEmpty)
    }

    func testTimeWindowOvernight() {
        let w = TimeWindow(fromHour: 22, toHour: 6)
        XCTAssertTrue(w.contains(minuteOfDay: 23 * 60))
        XCTAssertTrue(w.contains(minuteOfDay: 5 * 60))
        XCTAssertFalse(w.contains(minuteOfDay: 12 * 60))
        XCTAssertEqual(TimeWindow(startMin: 6 * 60 + 30, endMin: 8 * 60).label, "6h30–8h")
    }

    func testOddEvenParking() throws {
        var e = try engine()
        _ = e.sighted(SignSighting(code: "P.131b"), odometer: 0, t: 0, minuteOfDay: 600, dayOfMonth: 16)
        XCTAssertTrue(e.update(DriveContext(t: 70, odometer: 20, dayOfMonth: 16, stoppedS: 65)).isEmpty)   // ngày chẵn
        XCTAssertEqual(e.update(DriveContext(t: 71, odometer: 20, dayOfMonth: 17, stoppedS: 66)).map(\.text), ["Đoạn này cấm đỗ xe"])
    }

    func testSpeedLimitHoldAndEndSign() throws {
        var e = try engine()
        _ = e.sighted(SignSighting(code: "P.127", value: 50), odometer: 0, t: 0, minuteOfDay: 600, dayOfMonth: 1)
        XCTAssertTrue(e.update(DriveContext(t: 1, odometer: 10, speedKmh: 52)).isEmpty)   // trong ngưỡng +3
        XCTAssertTrue(e.update(DriveContext(t: 2, odometer: 20, speedKmh: 60)).isEmpty)   // mới vượt
        XCTAssertEqual(e.update(DriveContext(t: 5.5, odometer: 60, speedKmh: 60)).map(\.text), ["Quá tốc độ, giới hạn 50"])
        // biển mới 40 thay 50
        _ = e.sighted(SignSighting(code: "P.127", value: 40), odometer: 100, t: 6, minuteOfDay: 600, dayOfMonth: 1)
        XCTAssertEqual(e.active.map(\.value), [40])
        _ = e.sighted(SignSighting(code: "DP.134"), odometer: 200, t: 10, minuteOfDay: 600, dayOfMonth: 1)
        XCTAssertTrue(e.active.isEmpty)
    }

    func testEndAllAndSafetyExpiry() throws {
        var e = try engine()
        _ = e.sighted(SignSighting(code: "P.130"), odometer: 0, t: 0, minuteOfDay: 600, dayOfMonth: 1)
        _ = e.sighted(SignSighting(code: "P.127", value: 60), odometer: 50, t: 1, minuteOfDay: 600, dayOfMonth: 1)
        _ = e.sighted(SignSighting(code: "DP.135"), odometer: 80, t: 2, minuteOfDay: 600, dayOfMonth: 1)
        XCTAssertTrue(e.active.isEmpty)
        // không có bản đồ: tự hết sau 1,5 km
        _ = e.sighted(SignSighting(code: "P.130"), odometer: 0, t: 0, minuteOfDay: 600, dayOfMonth: 1)
        _ = e.update(DriveContext(t: 50, odometer: 1400))
        XCTAssertEqual(e.active.count, 1)
        _ = e.update(DriveContext(t: 60, odometer: 1600))
        XCTAssertTrue(e.active.isEmpty)
    }

    func testSameSignSeenTwiceIsIgnoredAndTurnClears() throws {
        var e = try engine()
        _ = e.sighted(SignSighting(code: "P.130"), odometer: 100, t: 0, minuteOfDay: 600, dayOfMonth: 1)
        _ = e.sighted(SignSighting(code: "P.130"), odometer: 110, t: 1, minuteOfDay: 600, dayOfMonth: 1)
        XCTAssertEqual(e.active.map(\.startOdo), [100])
        _ = e.update(DriveContext(t: 5, odometer: 160, turn: TurnEvent(direction: .right, angleDeg: 90, t: 5)))
        XCTAssertTrue(e.active.isEmpty)
    }
}

@testable import SafeGapCore
import XCTest

final class SignDetectionTests: XCTestCase {
    let W = 1920.0, H = 1080.0

    func sign(_ g: SignGroup, _ x: Double, _ y: Double = 300, size: Double = 30, conf: Double = 0.7) -> Detection {
        Detection(x, y, x + size, y + size, g.rawValue, conf)
    }

    func testNeedsThreeHitsAndReportsOnce() {
        var tr = SignDetectionTracker()
        XCTAssertTrue(tr.update(t: 0, signs: [sign(.noStopPark, 1500)], vehicles: [], frameWidth: W, frameHeight: H).isEmpty)
        XCTAssertTrue(tr.update(t: 0.3, signs: [sign(.noStopPark, 1520)], vehicles: [], frameWidth: W, frameHeight: H).isEmpty)
        let c = tr.update(t: 0.6, signs: [sign(.noStopPark, 1545, size: 34)], vehicles: [], frameWidth: W, frameHeight: H)
        XCTAssertEqual(c.map(\.group), [.noStopPark])
        XCTAssertEqual(c.first?.sighting, SignSighting(code: "P.130"))
        XCTAssertEqual(tr.visible.count, 1)
        // vẫn thấy tiếp: không báo lại
        XCTAssertTrue(tr.update(t: 0.9, signs: [sign(.noStopPark, 1570, size: 38)], vehicles: [], frameWidth: W, frameHeight: H).isEmpty)
    }

    func testFlickerAndLowConfidenceIgnored() {
        var tr = SignDetectionTracker()
        _ = tr.update(t: 0, signs: [sign(.noEntry, 900)], vehicles: [], frameWidth: W, frameHeight: H)
        _ = tr.update(t: 2.0, signs: [sign(.noEntry, 900)], vehicles: [], frameWidth: W, frameHeight: H)   // quá cửa sổ
        XCTAssertTrue(tr.update(t: 2.3, signs: [sign(.noEntry, 900, conf: 0.2)], vehicles: [], frameWidth: W, frameHeight: H).isEmpty)
        XCTAssertTrue(tr.visible.isEmpty)
    }

    func testSignOnTruckAndLowSignsIgnored() {
        var tr = SignDetectionTracker()
        let truck = Detection(800, 400, 1200, 900, "truck", 0.9)
        for (i, t) in [0.0, 0.3, 0.6, 0.9].enumerated() {
            let out = tr.update(t: t, signs: [sign(.speedLimit, 950 + Double(i), y: 500), sign(.warning, 200, y: 950)],
                                vehicles: [truck], frameWidth: W, frameHeight: H)
            XCTAssertTrue(out.isEmpty)
        }
    }

    func testCooldownAcrossBrokenTrackAndGroupsWithoutCode() {
        var tr = SignDetectionTracker()
        var got: [SignGroup] = []
        for t in stride(from: 0.0, through: 0.6, by: 0.3) {
            got += tr.update(t: t, signs: [sign(.noTurn, 1400)], vehicles: [], frameWidth: W, frameHeight: H).map(\.group)
        }
        // track đứt rồi thấy lại cùng nhóm sau 3 s: trong cooldown, không báo
        for t in stride(from: 3.6, through: 4.2, by: 0.3) {
            got += tr.update(t: t, signs: [sign(.noTurn, 1400)], vehicles: [], frameWidth: W, frameHeight: H).map(\.group)
        }
        XCTAssertEqual(got, [.noTurn])
        XCTAssertNil(ConfirmedSign(group: .noTurn, box: Box(0, 0, 1, 1), conf: 1, t: 0).sighting)
    }

    func testGroupNamesMatchTrainingScript() {
        // proto/dataset.py SIGN_GROUPS: cùng thứ tự để chỉ số lớp của model khớp
        XCTAssertEqual(SignGroup.allCases.map(\.rawValue),
                       ["no_entry", "no_stop_park", "no_turn", "speed_limit", "prohibit_other", "mandatory", "warning",
                        "end_restriction", "sign_other"])
    }
}

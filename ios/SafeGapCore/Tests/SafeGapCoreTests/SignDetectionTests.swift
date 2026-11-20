@testable import SafeGapCore
import XCTest

final class SignDetectionTests: XCTestCase {
    let W = 1920.0, H = 1080.0

    func sign(_ g: SignGroup, _ x: Double, y: Double = 300, size: Double = 30, conf: Double = 0.7) -> Detection {
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
                        "end_restriction", "sign_other", "no_park", "lane_sign", "aux_plate"])
    }

    /// Biển giả: viền đỏ, nền xanh, 1 hoặc 2 vạch đỏ chéo.
    private func signPixels(slashes: Int, n: Int = 16) -> [(r: Double, g: Double, b: Double, u: Double, v: Double)] {
        var out: [(r: Double, g: Double, b: Double, u: Double, v: Double)] = []
        for j in 0..<n {
            for i in 0..<n {
                let u = (Double(i) + 0.5) / Double(n), v = (Double(j) + 0.5) / Double(n)
                let rad = ((u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5)).squareRoot()
                let on = rad > 0.4 || abs(u - v) < 0.07 || (slashes == 2 && abs(u + v - 1) < 0.07)
                out.append(on ? (217, 25, 25, u, v) : (25, 76, 204, u, v))
            }
        }
        return out
    }

    func testSlashCountSplitsNoStopAndNoPark() {
        XCTAssertEqual(NoStopParkClassifier.classify(signPixels(slashes: 2)), "P.130")
        XCTAssertEqual(NoStopParkClassifier.classify(signPixels(slashes: 1)), "P.131a")
        XCTAssertNil(NoStopParkClassifier.classify([]))
    }

    func testTrackerVotesReadCodeIntoSighting() {
        var tr = SignDetectionTracker()
        var out: [ConfirmedSign] = []
        for (k, t) in [0.0, 0.3, 0.6].enumerated() {
            out = tr.update(t: t, signs: [sign(.noStopPark, 1500 + Double(k) * 20, size: 30 + Double(k) * 4)],
                            vehicles: [], frameWidth: W, frameHeight: H, codes: [k == 0 ? nil : "P.131a"])
        }
        XCTAssertEqual(out.first?.code, "P.131a")
        XCTAssertEqual(out.first?.sighting?.code, "P.131a")
        XCTAssertEqual(ConfirmedSign(group: .noPark, box: Box(0, 0, 1, 1), conf: 1, t: 0).sighting?.code, "P.131a")
    }
}

/// Vị trí cắm biển (QCVN 41: biển có hiệu lực cho phần đường bên trái nó theo hướng nhìn tài xế).
final class SignPlacementTests: XCTestCase {
    let W = 1920.0, H = 1080.0, F = 1500.0

    /// Biển cao 42 px ở f 1500 → cách 25 m; lệch ngang `x` mét.
    func sign(_ g: SignGroup, lateral x: Double, width: Double = 42) -> Detection {
        let cx = W / 2 + x * F / 25
        return Detection(cx - width / 2, 300, cx + width / 2, 342, g.rawValue, 0.8)
    }

    func confirm(_ d: Detection) -> ConfirmedSign? {
        var tr = SignDetectionTracker()
        var out: [ConfirmedSign] = []
        for t in [0.0, 0.3, 0.6] {
            out += tr.update(t: t, signs: [d], vehicles: [], frameWidth: W, frameHeight: H, fPx: F)
        }
        return out.first
    }

    func testPlacementFromBox() throws {
        let right = try XCTUnwrap(confirm(sign(.noStopPark, lateral: 4)))
        XCTAssertEqual(right.placement, .applies)
        XCTAssertEqual(right.distanceM ?? 0, 25, accuracy: 0.1)
        XCTAssertEqual(right.lateralM ?? 0, 4, accuracy: 0.1)
        XCTAssertEqual(confirm(sign(.noEntry, lateral: -3))?.placement, .leftOfUs)
        XCTAssertEqual(confirm(sign(.noEntry, lateral: 14))?.placement, .farRight)
        XCTAssertEqual(confirm(sign(.noEntry, lateral: 3, width: 20))?.placement, .turnedAway)
        XCTAssertNil(confirm(sign(.noStopPark, lateral: -3))?.sighting)
    }

    /// Biển cách `z` m, lệch `x` m (cỡ 0,7 m).
    func sign(_ g: SignGroup, z: Double, x: Double) -> Detection {
        let hpx = F * 0.7 / z, cx = W / 2 + x * F / z
        return Detection(cx - hpx / 2, 300, cx + hpx / 2, 300 + hpx, g.rawValue, 0.8)
    }

    func testFarSignWaitsUntilCloseOrGone() {
        var tr = SignDetectionTracker()
        // xa 60 m: đủ phiếu nhưng chưa chốt
        for t in [0.0, 0.3, 0.6] {
            XCTAssertTrue(tr.update(t: t, signs: [sign(.noEntry, z: 60, x: -2)], vehicles: [], frameWidth: W, frameHeight: H,
                                    fPx: F).isEmpty)
        }
        // tới gần 25 m: lộ rõ là biển bên trái (giữa đường) → không áp dụng
        let c = tr.update(t: 0.9, signs: [sign(.noEntry, z: 25, x: -2)], vehicles: [], frameWidth: W, frameHeight: H, fPx: F)
        XCTAssertEqual(c.first?.placement, .leftOfUs)
        // biển chỉ thấy khi xa rồi mất (bị che): chốt khi ra khỏi khung theo vị trí cuối
        var tr2 = SignDetectionTracker()
        for t in [0.0, 0.3, 0.6] {
            _ = tr2.update(t: t, signs: [sign(.noStopPark, z: 50, x: 4)], vehicles: [], frameWidth: W, frameHeight: H, fPx: F)
        }
        let gone = tr2.update(t: 2.5, signs: [], vehicles: [], frameWidth: W, frameHeight: H, fPx: F)
        XCTAssertEqual(gone.map(\.group), [.noStopPark])
        XCTAssertEqual(gone.first?.placement, .applies)
    }

    func testLeftThresholdAndOneWay() {
        var tr = SignDetectionTracker()
        XCTAssertEqual(tr.place(sign(.noEntry, z: 20, x: -1.3).box, frameWidth: W, fPx: F).0, .leftOfUs)
        tr.leftSideApplies = true   // đường một chiều: biển bên trái cũng cho mình
        XCTAssertEqual(tr.place(sign(.noEntry, z: 20, x: -4).box, frameWidth: W, fPx: F).0, .applies)
    }

    func engine() throws -> SignEngine { SignEngine(config: try SignTests.repoConfig()) }

    /// Biển rộng 0,7 m: mép trái = tâm − 0,35 m.
    func confirmed(_ g: SignGroup, _ p: SignPlacement, lateral: Double, ahead: Double = 25) -> ConfirmedSign {
        ConfirmedSign(group: g, box: Box(0, 0, 1, 1), conf: 0.8, t: 0, distanceM: ahead, lateralM: lateral, placement: p,
                      leftEdgeM: lateral - 0.35)
    }

    func testNoStopStartsAtSignNotWhenSeen() throws {
        var e = try engine()
        XCTAssertTrue(e.feed(confirmed(.noStopPark, .applies, lateral: 4), odometer: 100, t: 0, minuteOfDay: 600, dayOfMonth: 1).isEmpty)
        XCTAssertTrue(e.active.isEmpty)
        // ngã tư nằm giữa xe và biển (biển cắm sau ngã tư): không xoá biển
        _ = e.update(DriveContext(t: 1, odometer: 110, junctionPassed: true))
        _ = e.update(DriveContext(t: 2, odometer: 126))
        XCTAssertEqual(e.active.map(\.code), ["P.130"])
        XCTAssertEqual(e.active.first?.startOdo ?? 0, 125, accuracy: 0.01)
    }

    func testTurnBeforeReachingSignDropsIt() throws {
        var e = try engine()
        _ = e.feed(confirmed(.noStopPark, .applies, lateral: 4), odometer: 100, t: 0, minuteOfDay: 600, dayOfMonth: 1)
        _ = e.update(DriveContext(t: 1, odometer: 110, turn: TurnEvent(direction: .right, angleDeg: 90, t: 1)))
        _ = e.update(DriveContext(t: 3, odometer: 140))
        XCTAssertTrue(e.active.isEmpty && e.pending.isEmpty)
    }

    func testNoEntryRightOfRightLaneLineSpeaksNow() throws {
        // vạch phải 1,75 m (không dò được làn); biển lề phải tâm 3 m, mép trái 2,65 m: có hiệu lực, nhắc ngay
        var e = try engine()
        let m = e.feed(confirmed(.noEntry, .applies, lateral: 3), odometer: 100, t: 0, minuteOfDay: 600, dayOfMonth: 1)
        XCTAssertEqual(m.map(\.kind), [.signViolation])
        // biển xa bên phải (đường nhánh / đường ngang) vẫn nằm bên phải vạch: theo quy tắc đơn giản là có hiệu lực
        var e2 = try engine()
        XCTAssertEqual(e2.feed(confirmed(.noEntry, .farRight, lateral: 12), odometer: 100, t: 0, minuteOfDay: 600,
                               dayOfMonth: 1).map(\.kind), [.signViolation])
    }

    func testNoEntryTouchingOrLeftOfOurLaneIgnored() throws {
        var e = try engine()
        // tâm 1,9 m nhưng mép trái 1,55 m < vạch phải 1,75 m: lấn vào làn mình (biển treo trên / cột sát làn) → bỏ
        XCTAssertTrue(e.feed(confirmed(.noEntry, .applies, lateral: 1.9), odometer: 100, t: 0, minuteOfDay: 600,
                             dayOfMonth: 1).isEmpty)
        // giữa đường / bên trái: bỏ, rẽ trái cũng không nói
        XCTAssertTrue(e.feed(confirmed(.noEntry, .leftOfUs, lateral: -3), odometer: 100, t: 0, minuteOfDay: 600,
                             dayOfMonth: 1).isEmpty)
        XCTAssertTrue(e.update(DriveContext(t: 2, odometer: 122, turning: .left)).isEmpty)
        XCTAssertTrue(e.pending.isEmpty && e.active.isEmpty)
        // biển quay xiên: bỏ
        XCTAssertTrue(e.feed(confirmed(.noEntry, .turnedAway, lateral: 3), odometer: 100, t: 0, minuteOfDay: 600,
                             dayOfMonth: 1).isEmpty)
        XCTAssertFalse(e.isOwnRoadSign(confirmed(.noEntry, .applies, lateral: 1.9)))
    }

    func testNoEntryUsesDetectedRightLaneLine() throws {
        // xe đang sát vạch trái, vạch phải cách 3 m: biển mép trái 2,65 m vẫn lấn làn → bỏ; 3,5 m → có hiệu lực
        var e = try engine()
        let line: (Double) -> Double = { _ in 3.0 }
        XCTAssertTrue(e.feed(confirmed(.noEntry, .applies, lateral: 3), odometer: 100, t: 0, minuteOfDay: 600,
                             dayOfMonth: 1, rightLaneLineM: line).isEmpty)
        XCTAssertEqual(e.feed(confirmed(.noEntry, .applies, lateral: 3.9), odometer: 100, t: 20, minuteOfDay: 600,
                              dayOfMonth: 1, rightLaneLineM: line).map(\.kind), [.signViolation])
        XCTAssertTrue(e.isOwnRoadSign(confirmed(.noEntry, .applies, lateral: 3.9), rightLaneLineM: line))
    }
}

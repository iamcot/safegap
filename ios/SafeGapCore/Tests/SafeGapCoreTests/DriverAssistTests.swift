import XCTest
@testable import SafeGapCore

final class RoadEventsTests: XCTestCase {
    func testOdometerIntegratesSpeedAndSkipsGaps() {
        var o = Odometer()
        o.update(t: 0, speedKmh: 36)
        for i in 1...10 { o.update(t: Double(i) * 0.1, speedKmh: 36) }   // 10 m/s × 1 s
        XCTAssertEqual(o.meters, 10, accuracy: 1e-6)
        o.update(t: 10, speedKmh: 36)   // khoảng trống 9 s: không cộng
        XCTAssertEqual(o.meters, 10, accuracy: 1e-6)
        o.update(t: 10.5, speedKmh: nil)
        o.update(t: 11, speedKmh: 72)
        XCTAssertEqual(o.meters, 20, accuracy: 1e-6)
    }

    func testStopDetectorHysteresis() {
        var s = StopDetector()
        XCTAssertNil(s.update(t: 0, speedKmh: 20))
        XCTAssertEqual(s.update(t: 1, speedKmh: 2), 0)
        XCTAssertEqual(s.update(t: 4, speedKmh: 4.5), 3)   // 4,5 km/h: vẫn coi là đứng (chưa quá 6)
        XCTAssertEqual(s.update(t: 5, speedKmh: nil), 4)
        XCTAssertNil(s.update(t: 6, speedKmh: 8))
        XCTAssertFalse(s.isStopped)
    }

    /// Chạy 10 m/s, quay đều `rate` °/s trong `turnS` giây rồi chạy thẳng.
    func runTurn(rate: Double, turnS: Double, gyro: Bool = true) -> [TurnEvent] {
        var d = TurnDetector()
        var out: [TurnEvent] = []
        var course = 90.0
        let dt = 1.0 / 15
        for i in 0..<Int(20 / dt) {
            let t = Double(i) * dt
            let r = (t >= 3 && t < 3 + turnS) ? rate : 0
            course += r * dt
            let c = (course.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            if let e = d.update(t: t, yawRateDegS: gyro ? r : nil, courseDeg: gyro ? nil : c, speedKmh: 36) {
                out.append(e)
            }
        }
        return out
    }

    func testTurnRightLeftUturn() {
        let right = runTurn(rate: 20, turnS: 4.5)   // 90°
        XCTAssertEqual(right.map(\.direction), [.right])
        XCTAssertEqual(right[0].angleDeg, 90, accuracy: 3)

        XCTAssertEqual(runTurn(rate: -18, turnS: 5).map(\.direction), [.left])
        XCTAssertEqual(runTurn(rate: -30, turnS: 6).map(\.direction), [.uturn])
    }

    func testTurnFromGPSCourseAcrossNorth() {
        // hướng 90° → qua 0° (bắc) → 330°: rẽ trái 120°, không bị nhảy 360°
        let ev = runTurn(rate: -20, turnS: 6, gyro: false)
        XCTAssertEqual(ev.map(\.direction), [.left])
        XCTAssertEqual(ev[0].angleDeg, -120, accuracy: 5)
    }

    func testGentleCurveAndLaneChangeAreNotTurns() {
        XCTAssertTrue(runTurn(rate: 3, turnS: 8).isEmpty)    // 24°
        XCTAssertTrue(runTurn(rate: 10, turnS: 1.5).isEmpty) // 15° (đổi làn)
    }

    func testAngleDiffWraps() {
        XCTAssertEqual(TurnDetector.angleDiff(10, 350), 20, accuracy: 1e-9)
        XCTAssertEqual(TurnDetector.angleDiff(350, 10), -20, accuracy: 1e-9)
    }

    func testJunctionTrackerPassesOnce() {
        var j = JunctionTracker()
        var passed: [Double] = []
        var odo = 0.0
        while odo < 200 {
            // OSM: ngã tư ở 100 m và 180 m tính từ lúc bắt đầu (dữ liệu tra lại liên tục, lệch ±2 m)
            let jitter = odo.truncatingRemainder(dividingBy: 7) < 3.5 ? 2.0 : -2.0
            let ahead = [100.0, 180.0].map { $0 + jitter - odo }.filter { $0 > -10 }
            let u = j.update(odometer: odo, junctionsAhead: ahead)
            if u.passed { passed.append(odo) }
            odo += 1
        }
        XCTAssertEqual(passed.count, 2)
        XCTAssertEqual(passed[0], 105, accuracy: 4)
        XCTAssertEqual(passed[1], 185, accuracy: 4)
    }

    func testJunctionTrackerKeepsTargetWithoutMap() {
        var j = JunctionTracker()
        XCTAssertEqual(j.update(odometer: 0, junctionsAhead: [50]).nextM, 50)
        XCTAssertEqual(j.update(odometer: 20, junctionsAhead: nil).nextM, 30)
        XCTAssertTrue(j.update(odometer: 56, junctionsAhead: nil).passed)
        XCTAssertNil(j.update(odometer: 60, junctionsAhead: nil).nextM)
    }
}

final class InferenceSchedulerTests: XCTestCase {
    func count(_ s: inout InferenceScheduler, _ task: InferenceTask, thermal: ThermalLevel, stopped: Bool) -> Double {
        var n = 0.0
        for i in 0..<300 where s.shouldRun(task, t: Double(i) / 30, thermal: thermal, isStopped: stopped) { n += 1 }
        return n   // trong 10 s camera 30 fps
    }

    func testRatesByThermalAndMotion() {
        var s = InferenceScheduler(vehicles: .cool)
        XCTAssertEqual(count(&s, .vehicles, thermal: .nominal, stopped: false), 150, accuracy: 2)
        s = InferenceScheduler(vehicles: .cool)
        XCTAssertEqual(count(&s, .vehicles, thermal: .nominal, stopped: true), 50, accuracy: 2)
        s = InferenceScheduler(vehicles: .cool)
        XCTAssertEqual(count(&s, .signsLights, thermal: .nominal, stopped: false), 40, accuracy: 2)
        s = InferenceScheduler(vehicles: .cool)
        XCTAssertEqual(count(&s, .signsLights, thermal: .critical, stopped: false), 0)
        s = InferenceScheduler(vehicles: .cool)
        XCTAssertEqual(count(&s, .carModel, thermal: .serious, stopped: false), 0)
        XCTAssertEqual(s.targetFps(.vehicles, thermal: .critical, isStopped: true), 5)
    }

    func testDueSet() {
        var s = InferenceScheduler(vehicles: .cool)
        XCTAssertEqual(s.due(t: 0, thermal: .nominal, isStopped: false), [.vehicles, .signsLights, .carModel])
        XCTAssertEqual(s.due(t: 1.0 / 30, thermal: .nominal, isStopped: false), [])
    }
}

final class VoicePolicyTests: XCTestCase {
    func testPriorityGapAndCooldowns() {
        var p = VoicePolicy()
        XCTAssertTrue(p.offer(VoiceMessage(kind: .carFun, text: "vui", t: 0)))
        XCTAssertTrue(p.offer(VoiceMessage(kind: .redLight, text: "Đèn đỏ", t: 0.1)))
        XCTAssertNil(p.next(t: 0.2, speaking: true))                 // đang nói: chờ
        XCTAssertEqual(p.next(t: 0.3, speaking: false)?.kind, .redLight)
        XCTAssertNil(p.next(t: 1.0, speaking: false))               // chưa hết nghỉ 1,5 s
        XCTAssertEqual(p.next(t: 2.0, speaking: false)?.kind, .carFun)
        // cùng loại trong thời gian nghỉ: bỏ
        XCTAssertFalse(p.offer(VoiceMessage(kind: .redLight, text: "Đèn đỏ khác", t: 3)))
        // cùng câu trong 60 s: bỏ
        XCTAssertFalse(p.offer(VoiceMessage(kind: .redLight, text: "Đèn đỏ", t: 30)))
        XCTAssertTrue(p.offer(VoiceMessage(kind: .redLight, text: "Đèn đỏ", t: 61)))
    }

    func testStaleMessagesDropped() {
        var p = VoicePolicy()
        p.offer(VoiceMessage(kind: .signReminder, text: "nhắc", t: 0))
        XCTAssertNil(p.next(t: 10, speaking: false))
        XCTAssertTrue(p.pending.isEmpty)
    }
}

final class TrafficLightTests: XCTestCase {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// Khung đèn: phần lớn vỏ đen + một ít điểm bóng đèn.
    func housing(lit: RGB, litCount: Int = 20, total: Int = 300) -> [RGB] {
        Array(repeating: (r: 20, g: 20, b: 22), count: total - litCount) + Array(repeating: lit, count: litCount)
    }

    func testColors() {
        XCTAssertEqual(LightColorClassifier.classify(housing(lit: (255, 40, 30))), .red)
        XCTAssertEqual(LightColorClassifier.classify(housing(lit: (255, 190, 20))), .yellow)
        XCTAssertEqual(LightColorClassifier.classify(housing(lit: (20, 230, 170))), .green)
        XCTAssertEqual(LightColorClassifier.classify(housing(lit: (240, 240, 240))), .unknown)  // trắng: không đậm màu
        XCTAssertEqual(LightColorClassifier.classify(housing(lit: (255, 40, 30), litCount: 2)), .unknown)
    }

    func testYCbCrRoundTripRed() {
        // đỏ thuần ~ Y 76, Cb 85, Cr 255 (BT.601 full range)
        let c = LightColorClassifier.rgb(y: 76, cb: 85, cr: 255)
        XCTAssertEqual(c.r, 254, accuracy: 3)
        XCTAssertEqual(c.g, 0, accuracy: 3)
        XCTAssertEqual(c.b, 0, accuracy: 3)
    }

    func testPickPrefersLargeUpperCentral() {
        let tr = TrafficLightTracker()
        let small = Detection(900, 100, 915, 130, "traffic light")
        let big = Detection(1100, 80, 1130, 160, "traffic light")
        let low = Detection(1000, 700, 1040, 800, "traffic light")   // dưới ảnh: thường là đèn xe
        let tiny = Detection(10, 10, 15, 20, "traffic light")
        XCTAssertEqual(tr.pick([small, big, low, tiny], frameWidth: 1920, frameHeight: 1080), big)
        XCTAssertNil(tr.pick([tiny], frameWidth: 1920, frameHeight: 1080))
    }

    func testPickSticksToCurrentLight() {
        var tr = TrafficLightTracker()
        let ours = Detection(1100, 80, 1130, 160, "traffic light")
        let other = Detection(700, 60, 735, 165, "traffic light")   // hơi to hơn, chỗ khác (đèn hướng khác)
        tr.update(t: 0, light: ours, color: .red)
        XCTAssertEqual(tr.pick([other, ours], frameWidth: 1920, frameHeight: 1080), ours)
        let huge = Detection(600, 40, 680, 240, "traffic light")    // to hơn hẳn: đổi
        XCTAssertEqual(tr.pick([huge, ours], frameWidth: 1920, frameHeight: 1080), huge)
    }

    func testVotingAndHold() throws {
        var tr = TrafficLightTracker()
        let d = Detection(1100, 80, 1130, 160, "traffic light")
        for i in 0..<5 { tr.update(t: Double(i) * 0.25, light: d, color: .red) }
        XCTAssertEqual(tr.state?.color, .red)
        // 1 frame nhiễu không đổi màu
        tr.update(t: 1.25, light: d, color: .green)
        XCTAssertEqual(tr.state?.color, .red)
        // 2 lần liên tiếp cùng màu rõ: đổi ngay (không chờ đủ 3/5 phiếu)
        tr.update(t: 1.5, light: d, color: .green)
        let s = try XCTUnwrap(tr.state)
        XCTAssertEqual(s.color, .green)
        XCTAssertEqual(s.since, 1.5, accuracy: 0.01)
        // 1 frame nhiễu đỏ sau đó không kéo ngược lại
        tr.update(t: 1.75, light: d, color: .red)
        XCTAssertEqual(tr.state?.color, .green)
        for i in 8..<9 { tr.update(t: Double(i) * 0.25, light: d, color: .green) }
        // mất đèn: giữ trạng thái 8 s
        tr.update(t: 5, light: nil, color: nil)
        XCTAssertEqual(tr.state?.color, .green)
        XCTAssertNil(tr.state?.box)
        tr.update(t: 11, light: nil, color: nil)
        XCTAssertNil(tr.state)
    }

    /// Khung đèn dọc 10×24 điểm, bóng sáng ở hàng `rows` với màu `lit`.
    func vertical(lit: RGB, rows: Range<Int>) -> [(r: Double, g: Double, b: Double, u: Double, v: Double)] {
        var out: [(r: Double, g: Double, b: Double, u: Double, v: Double)] = []
        for j in 0..<24 {
            for i in 0..<10 {
                let c: RGB = rows.contains(j) && (3...6).contains(i) ? lit : (r: 20, g: 20, b: 22)
                out.append((r: c.r, g: c.g, b: c.b, u: (Double(i) + 0.5) / 10, v: (Double(j) + 0.5) / 24))
            }
        }
        return out
    }

    func testPositionDecidesAmbiguousHue() {
        let orange: RGB = (r: 255, g: 120, b: 20)    // hue ~25: đỏ LED qua camera hay ra màu này
        XCTAssertEqual(LightColorClassifier.classify(vertical(lit: orange, rows: 2..<6), aspect: 2.5), .red)
        let amber: RGB = (r: 255, g: 190, b: 20)
        XCTAssertEqual(LightColorClassifier.classify(vertical(lit: amber, rows: 10..<14), aspect: 2.5), .yellow)
        XCTAssertEqual(LightColorClassifier.classify(vertical(lit: amber, rows: 2..<6), aspect: 2.5), .red)
        let green: RGB = (r: 20, g: 230, b: 170)
        XCTAssertEqual(LightColorClassifier.classify(vertical(lit: green, rows: 18..<22), aspect: 2.5), .green)
        // khung vuông (không rõ hướng): theo hue
        XCTAssertEqual(LightColorClassifier.classify(vertical(lit: amber, rows: 2..<6), aspect: 1), .yellow)
    }

    func testRedNeverTurnsYellow() {
        var tr = TrafficLightTracker()
        let d = Detection(1100, 80, 1130, 160, "traffic light")
        for i in 0..<5 { tr.update(t: Double(i) * 0.25, light: d, color: .red) }
        for i in 5..<9 { tr.update(t: Double(i) * 0.25, light: d, color: .yellow) }   // quầng đỏ ban đêm ra vàng
        XCTAssertEqual(tr.state?.color, .red)
        for i in 9..<11 { tr.update(t: Double(i) * 0.25, light: d, color: .green) }
        XCTAssertEqual(tr.state?.color, .green)
        for i in 11..<13 { tr.update(t: Double(i) * 0.25, light: d, color: .yellow) }   // xanh → vàng vẫn được
        XCTAssertEqual(tr.state?.color, .yellow)
    }

    func testUnknownMajorityClearsColor() {
        var tr = TrafficLightTracker()
        let d = Detection(1100, 80, 1130, 160, "traffic light")
        for i in 0..<5 { tr.update(t: Double(i) * 0.25, light: d, color: .yellow) }
        XCTAssertEqual(tr.state?.color, .yellow)
        // vẫn thấy khung nhưng không rõ màu (vd vật khác giống đèn): không giữ vàng mãi
        for i in 5..<8 { tr.update(t: Double(i) * 0.25, light: d, color: .unknown) }
        XCTAssertEqual(tr.state?.color, .unknown)
    }

    func testHoldShortWhenMoving() {
        var tr = TrafficLightTracker()
        let d = Detection(1100, 80, 1130, 160, "traffic light")
        for i in 0..<5 { tr.update(t: Double(i) * 0.25, light: d, color: .red, speedKmh: 40) }
        // chui hầm: mất đèn khi đang chạy → bỏ sau 2 s
        tr.update(t: 2.5, light: nil, color: nil, speedKmh: 40)
        XCTAssertEqual(tr.state?.color, .red)
        tr.update(t: 3.5, light: nil, color: nil, speedKmh: 40)
        XCTAssertNil(tr.state)
    }

    func testLightAlerts() {
        let rules = LightAlertRules()
        let box = Box(1100, 80, 1130, 160)
        let red = TrafficLightState(color: .red, since: 0, lastSeen: 1, box: box, heightPx: 80)
        // 50 km/h, ngã tư còn 40 m: cần phanh ~2,4 m/s² → nhắc
        XCTAssertEqual(rules.check(state: red, t: 1, speedKmh: 50, junctionM: 40, stoppedS: nil)?.kind, .redLight)
        // 30 km/h còn 80 m: phanh nhẹ là đủ → không nhắc
        XCTAssertNil(rules.check(state: red, t: 1, speedKmh: 30, junctionM: 80, stoppedS: nil))
        // không bản đồ: theo độ to của đèn
        XCTAssertNotNil(rules.check(state: red, t: 1, speedKmh: 40, junctionM: nil, stoppedS: nil))
        // đang giữ trạng thái (mất đèn): không nhắc
        var held = red
        held.box = nil
        XCTAssertNil(rules.check(state: held, t: 1, speedKmh: 50, junctionM: 40, stoppedS: nil))

        let green = TrafficLightState(color: .green, since: 10, lastSeen: 13, box: box, heightPx: 80)
        XCTAssertNil(rules.check(state: green, t: 11, speedKmh: 0, junctionM: nil, stoppedS: 30))
        XCTAssertEqual(rules.check(state: green, t: 13, speedKmh: 0, junctionM: nil, stoppedS: 30)?.kind, .lightInfo)
        XCTAssertNil(rules.check(state: green, t: 13, speedKmh: 20, junctionM: nil, stoppedS: nil))
    }
}

final class CaptureTests: XCTestCase {
    func testYOLOLine() {
        let d = Detection(960, 540, 1152, 756, "car")
        XCTAssertEqual(YOLOLabel.line(d, frameWidth: 1920, frameHeight: 1080), "0 0.550000 0.600000 0.100000 0.200000")
        let l = Detection(-10, 0, 10, 54, "traffic light")   // tràn mép: cắt lại
        XCTAssertEqual(YOLOLabel.line(l, frameWidth: 1920, frameHeight: 1080), "4 0.002604 0.025000 0.005208 0.050000")
        XCTAssertNil(YOLOLabel.line(Detection(0, 0, 10, 10, "person"), frameWidth: 1920, frameHeight: 1080))
        XCTAssertEqual(YOLOLabel.file([d, Detection(0, 0, 10, 10, "person")], frameWidth: 1920, frameHeight: 1080).split(separator: "\n").count, 1)
    }

    func testCapturePolicy() {
        var p = CapturePolicy()
        var n = 0
        for i in 0..<300 where p.shouldCapture(t: Double(i) / 15, speedKmh: 40, hasLight: false) { n += 1 }
        XCTAssertEqual(n, 5)   // 20 s, mỗi 4 s
        var q = CapturePolicy()
        XCTAssertFalse(q.shouldCapture(t: 0, speedKmh: 0, hasLight: false))
        XCTAssertTrue(q.shouldCapture(t: 0, speedKmh: 0, hasLight: true))
        XCTAssertFalse(q.shouldCapture(t: 1.5, speedKmh: 0, hasLight: true))
        XCTAssertTrue(q.shouldCapture(t: 2.0, speedKmh: 0, hasLight: true))
        q.maxImages = 2
        XCTAssertFalse(q.shouldCapture(t: 5, speedKmh: 40, hasLight: false))
        // model đang thấy biển: mỗi 1,5 s khi xe chạy, đứng yên thì không
        var s = CapturePolicy()
        var m = 0
        for i in 0..<150 where s.shouldCapture(t: Double(i) / 15, speedKmh: 30, hasLight: false, hasSign: true) { m += 1 }
        XCTAssertEqual(m, 7)   // 10 s
        var still = CapturePolicy()
        XCTAssertFalse(still.shouldCapture(t: 0, speedKmh: 0, hasLight: false, hasSign: true))
    }
}

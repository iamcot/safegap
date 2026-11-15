import XCTest
@testable import SafeGapCore

final class LaneTests: XCTestCase {
    static let W = 320, H = 180
    let roi = [Point(0.42, 0.45), Point(0.58, 0.45), Point(0.80, 1.0), Point(0.20, 1.0)]

    /// Nền đường tối có nhiễu, vẽ các vạch x = f(y) (chuẩn hoá). dashed: vạch đứt.
    func road(_ lines: [(f: (Double) -> Double, dashed: Bool)], seed: UInt32 = 7) -> GrayImage {
        var img = GrayImage(width: Self.W, height: Self.H)
        var r = seed
        for i in 0..<img.pixels.count {
            r = r &* 1_103_515_245 &+ 12_345
            img.pixels[i] = UInt8(55 + Int((r >> 16) % 20))
        }
        for py in Int(0.45 * Double(Self.H))..<Self.H {
            let y = Double(py) / Double(Self.H)
            let half = max(1, Int(1 + 3 * (y - 0.45) / 0.55))  // vạch to dần khi lại gần
            for l in lines {
                if l.dashed && (py / 8) % 2 == 1 { continue }
                let cx = Int(l.f(y) * Double(Self.W))
                for x in (cx - half)...(cx + half) where x >= 0 && x < Self.W { img[x, py] = 210 }
            }
        }
        return img
    }

    func center(_ y: Double) -> Double { LaneROI.center(at: y, left: nil, right: nil, calibrated: roi) }

    func testStraightLanesWithNeighbourLane() throws {
        let left = { (y: Double) in 0.30 + (0.47 - 0.30) * (1 - y) / 0.55 }
        let right = { (y: Double) in 0.72 + (0.53 - 0.72) * (1 - y) / 0.55 }
        let far = { (y: Double) in 1.10 + (0.60 - 1.10) * (1 - y) / 0.55 }  // vạch làn bên phải nữa
        let d = LaneDetector.detect(road([(left, false), (right, true), (far, false)]), center: center)
        let l = try XCTUnwrap(d.left), r = try XCTUnwrap(d.right)
        for y in [0.6, 0.75, 0.9] {
            XCTAssertEqual(l.x(at: y), left(y), accuracy: 0.012, "trái y=\(y)")
            XCTAssertEqual(r.x(at: y), right(y), accuracy: 0.012, "phải y=\(y)")
        }
    }

    func testCurvedLane() throws {
        let left = { (y: Double) in 0.32 + 0.6 * (1 - y) * (1 - y) + 0.05 * (1 - y) }
        let right = { (y: Double) in 0.70 + 0.6 * (1 - y) * (1 - y) - 0.30 * (1 - y) }
        let d = LaneDetector.detect(road([(left, false), (right, false)]), center: { y in (left(y) + right(y)) / 2 })
        let l = try XCTUnwrap(d.left), r = try XCTUnwrap(d.right)
        XCTAssertNotEqual(l.c2, 0)
        for y in [0.6, 0.75, 0.9] {
            XCTAssertEqual(l.x(at: y), left(y), accuracy: 0.015)
            XCTAssertEqual(r.x(at: y), right(y), accuracy: 0.015)
        }
    }

    func testNoMarkings() {
        let d = LaneDetector.detect(road([]), center: center)
        XCTAssertNil(d.left)
        XCTAssertNil(d.right)
        XCTAssertNil(LaneROI.polygon(left: nil, right: nil, calibrated: roi))
    }

    func testPolygonFromOneSideUsesCalibratedWidth() throws {
        let l = LaneCurve(c0: 0.25, c1: -0.3, yRef: 1.0)  // x = 0.25 - 0.3*(y-1)
        let poly = try XCTUnwrap(LaneROI.polygon(left: l, right: nil, calibrated: roi, steps: 4))
        XCTAssertEqual(poly.count, 10)
        XCTAssertEqual(poly[4].y, 1.0, accuracy: 1e-12)
        XCTAssertEqual(poly[4].x, 0.25, accuracy: 1e-12)
        XCTAssertEqual(poly[5].x, 0.25 + 0.6, accuracy: 1e-9)  // bề rộng ROI hiệu chỉnh ở đáy = 0.6
        XCTAssertEqual(poly[0].y, 0.45, accuracy: 1e-12)
    }

    func testLaneROISelectsCarOnCurve() {
        // đường cong sang phải: xe làn mình lệch phải, ROI cố định chọn nhầm xe làn trái
        let l = LaneCurve(c0: 0.30, c1: -0.6, c2: 1.2, yRef: 1.0)
        let r = LaneCurve(c0: 0.72, c1: -0.1, c2: 1.2, yRef: 1.0)
        let poly = LaneROI.polygon(left: l, right: r, calibrated: roi)!
        let px = Lane.roiToPixels(poly, width: 1920, height: 1080)
        let fixed = Lane.roiToPixels(roi, width: 1920, height: 1080)
        let y = 0.62
        let mine = Detection((l.x(at: y) + r.x(at: y)) / 2 * 1920 - 40, y * 1080 - 60, (l.x(at: y) + r.x(at: y)) / 2 * 1920 + 40, y * 1080, "car")
        let other = Detection(900, 640, 1000, 700, "car")  // giữa khung, nhưng là làn trái trên đoạn cong
        XCTAssertEqual(Lane.selectEgo([other, mine], roi: px), 1)
        XCTAssertEqual(Lane.selectEgo([other, mine], roi: fixed), 0)
    }

    func testTrackerHoldsThenDrops() {
        var t = LaneTracker(smoothing: 0.5, maxMissed: 2)
        let a = LaneCurve(c0: 0.3, c1: -0.3), b = LaneCurve(c0: 0.4, c1: -0.3)
        t.update(LaneDetection(left: a, right: nil, leftPoints: 10, rightPoints: 0))
        t.update(LaneDetection(left: b, right: nil, leftPoints: 10, rightPoints: 0))
        XCTAssertEqual(t.left!.c0, 0.35, accuracy: 1e-12)
        t.update(LaneDetection(left: nil, right: nil, leftPoints: 0, rightPoints: 0))
        t.update(LaneDetection(left: nil, right: nil, leftPoints: 0, rightPoints: 0))
        XCTAssertNotNil(t.left)
        t.update(LaneDetection(left: nil, right: nil, leftPoints: 0, rightPoints: 0))
        XCTAssertNil(t.left)
    }
}

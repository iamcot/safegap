import XCTest
@testable import SafeGapCore

final class RoadLaneTests: XCTestCase {
    func line(_ x0: Double, _ slope: Double = 0, _ a2: Double = 0) -> [(x: Double, z: Double)] {
        stride(from: 5.0, through: 40.0, by: 2.5).map { z in (x0 + slope * z + a2 * z * z, z) }
    }

    func testFitRecoversParabola() {
        let f = RoadLaneFilter().fit(line(-1.6, 0.02, 0.001))!
        XCTAssertEqual(f.a0, -1.6, accuracy: 1e-6)
        XCTAssertEqual(f.a1, 0.02, accuracy: 1e-6)
        XCTAssertEqual(f.a2, 0.001, accuracy: 1e-8)
    }

    func testStraightLaneFirstFrame() {
        let lane = RoadLaneFilter().update(left: line(-1.9), right: line(1.6))
        XCTAssertEqual(lane.offset, -0.15, accuracy: 1e-6)
        XCTAssertEqual(lane.width, 3.5, accuracy: 1e-6)
        XCTAssertEqual(lane.heading, 0, accuracy: 1e-6)
        XCTAssertTrue(lane.tracked)
    }

    func testImplausibleDetectionIgnored() {
        let f = RoadLaneFilter()
        f.update(left: line(-1.75), right: line(1.75))
        // vạch chéo hẳn sang (góc ~20°) là nhận nhầm: không được làm lệch làn
        for _ in 0..<10 { f.update(left: line(-1.75, 0.35), right: nil) }
        XCTAssertEqual(f.lane.offset, 0, accuracy: 1e-6)
        XCTAssertEqual(f.lane.heading, 0, accuracy: 1e-6)
    }

    func testLaneChangeWrapsInsteadOfDraggingAcross() {
        let f = RoadLaneFilter()
        f.update(left: line(-1.75), right: line(1.75))
        // xe dạt dần sang trái tới khi vạch trái nằm dưới xe rồi qua hẳn làn trái
        for i in 0...40 {
            let o = min(2.2, 0.06 * Double(i))
            f.update(left: line(-1.75 + o), right: line(1.75 + o))
        }
        // giờ thấy vạch của làn mới (tâm làn lệch -1,3 m): mô hình đã đổi gốc, không kéo ngang qua giữa
        var maxJump = 0.0, prev = f.lane.offset
        for _ in 0..<30 {
            f.update(left: line(-3.05), right: line(0.45))
            let d = f.lane.offset - prev, w = f.lane.width   // đổi gốc (±1 làn) không phải là nhảy
            maxJump = max(maxJump, min(abs(d), abs(d - w), abs(d + w))); prev = f.lane.offset
        }
        XCTAssertEqual(f.lane.offset, -1.3, accuracy: 0.1)
        XCTAssertLessThanOrEqual(maxJump, f.config.maxOffsetStep + 1e-9)
    }

    func testOneSideTooLongAsksReacquireAndStationaryRelaxes() {
        let f = RoadLaneFilter()
        f.update(left: line(-1.75), right: line(1.75))
        for _ in 0...f.config.oneSideMaxFrames { f.update(left: nil, right: line(1.75)) }
        XCTAssertTrue(f.needsReacquire)
        f.update(left: line(-1.75), right: line(1.75))
        XCTAssertFalse(f.needsReacquire)
        for _ in 0..<(f.config.holdFrames + 5) { f.stationary() }
        XCTAssertFalse(f.lane.tracked)
    }

    func testSlowSmoothFollow() {
        let f = RoadLaneFilter()
        f.update(left: line(-1.75), right: line(1.75))
        // xe dạt sang trái 1 m: mô hình theo từ từ, mỗi frame không quá maxOffsetStep
        f.update(left: line(-0.75), right: line(2.75))
        XCTAssertLessThanOrEqual(f.lane.offset, f.config.maxOffsetStep + 1e-9)
        XCTAssertGreaterThan(f.lane.offset, 0)
        for _ in 0..<60 { f.update(left: line(-0.75), right: line(2.75)) }
        XCTAssertEqual(f.lane.offset, 1.0, accuracy: 0.02)
    }

    func testConflictingPairKeepsSideCloserToModel() {
        let f = RoadLaneFilter()
        f.update(left: line(-1.75), right: line(1.75))
        // vạch phải nhận nhầm sang làn bên (rộng 7 m): giữ vạch trái, bề rộng không đổi
        f.update(left: line(-1.75), right: line(5.25))
        XCTAssertEqual(f.lane.offset, 0, accuracy: 1e-6)
        XCTAssertEqual(f.lane.width, 3.5, accuracy: 1e-6)
    }

    func testHoldThenRelaxToStraight() {
        let f = RoadLaneFilter()
        f.update(left: line(-1.0, 0.03), right: line(2.5, 0.03))
        let held = f.lane
        for _ in 0..<f.config.holdFrames { f.update(left: nil, right: nil) }
        XCTAssertEqual(f.lane.offset, held.offset, accuracy: 1e-12)
        XCTAssertTrue(f.lane.tracked)
        for _ in 0..<400 { f.update(left: nil, right: nil) }
        XCTAssertEqual(f.lane.offset, 0, accuracy: 0.01)
        XCTAssertEqual(f.lane.heading, 0, accuracy: 0.001)
        XCTAssertFalse(f.lane.tracked)
    }
}

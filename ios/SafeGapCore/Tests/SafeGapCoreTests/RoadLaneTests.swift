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

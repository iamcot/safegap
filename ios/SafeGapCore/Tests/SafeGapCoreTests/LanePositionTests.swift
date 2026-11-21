@testable import SafeGapCore
import XCTest

final class LanePositionTests: XCTestCase {
    /// Gọi `update` 3 frame liên tiếp (một làn phải thấy ≥ 3 frame mới tính).
    private func feed(_ e: inout LanePositionEstimator, t: Double, _ offs: [Int], lanes: Int?,
                      oncoming: Int? = nil, gps: Int? = nil) -> LanePosition {
        var p = LanePosition(fromLeft: 0, lanes: 1, source: .none)
        for i in 0..<3 { p = e.update(t: t + Double(i) * 0.1, laneOffsets: offs, oncomingLanesLeft: oncoming, lanesSame: lanes, gpsFromRight: gps) }
        return p
    }

    func testCarsBothSidesMeansMiddleLane() {
        var e = LanePositionEstimator()
        let p = feed(&e, t: 0, [-1, 1], lanes: 3)
        XCTAssertEqual(p, LanePosition(fromLeft: 1, lanes: 3, source: .vehicles))
        XCTAssertEqual(p.fromRight, 1)
    }

    func testOnlyRightMeansLeftmostOnlyLeftMeansRightmost() {
        var e = LanePositionEstimator()
        XCTAssertEqual(feed(&e, t: 0, [1], lanes: 3).fromLeft, 0)
        var e2 = LanePositionEstimator()
        let p = feed(&e2, t: 0, [-1, -2], lanes: 3)
        XCTAssertEqual(p.fromLeft, 2)
        XCTAssertEqual(p.fromRight, 0)
    }

    func testSingleFrameNoiseIgnored() {
        var e = LanePositionEstimator()
        _ = e.update(t: 0, laneOffsets: [-2, 2], lanesSame: 3)
        let p = e.update(t: 0.1, laneOffsets: [], lanesSame: 3)
        XCTAssertEqual(p.source, .none)
        XCTAssertEqual(p.lanes, 3)
    }

    func testMemoryAndLaneChange() {
        var e = LanePositionEstimator()
        _ = feed(&e, t: 0, [-1], lanes: 3)
        // xe bên trái khuất khỏi hình nhưng vẫn nhớ; thấy thêm xe bên phải → làn giữa
        XCTAssertEqual(feed(&e, t: 2, [1], lanes: 3).fromLeft, 1)
        // đổi sang làn trái: xe bên trái (1 làn) giờ là làn mình → quên; xe bên phải cách 2 làn
        e.laneChanged(-1)
        XCTAssertEqual(e.update(t: 3, laneOffsets: [], lanesSame: 3).fromLeft, 0)
        // quá 6 s không thấy ai: về GPS / mặc định
        XCTAssertEqual(e.update(t: 10, laneOffsets: [], lanesSame: 3, gpsFromRight: 0).source, .gps)
        XCTAssertEqual(e.update(t: 10, laneOffsets: [], lanesSame: 3, gpsFromRight: 0).fromLeft, 2)
        XCTAssertEqual(e.update(t: 10, laneOffsets: [], lanesSame: 3).source, .none)
    }

    func testLanesCappedByMap() {
        // OSM 2 làn, camera thấy xe 2 làn trái + 1 làn phải: tin thêm tối đa 1 làn → 3 làn, làn giữa
        var e = LanePositionEstimator()
        let p = feed(&e, t: 0, [-2, 1], lanes: 2)
        XCTAssertEqual(p.lanes, 3)
        XCTAssertEqual(p.fromLeft, 1)
        // không có OSM: tối đa 4 làn
        var e2 = LanePositionEstimator()
        XCTAssertEqual(feed(&e2, t: 0, [-2, 2], lanes: nil).lanes, 4)
        // xe ngược chiều ngay bên kia vạch giữa: làn sát vạch giữa
        var e3 = LanePositionEstimator()
        XCTAssertEqual(feed(&e3, t: 0, [1], lanes: 2, oncoming: 1).source, .oncoming)
    }
}

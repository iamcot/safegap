@testable import SafeGapCore
import XCTest

final class LanePositionTests: XCTestCase {
    func testCarsBothSidesMeansMiddleLane() {
        var e = LanePositionEstimator()
        let p = e.update(t: 0, laneOffsets: [-1, 1], lanesSame: 3)
        XCTAssertEqual(p, LanePosition(fromLeft: 1, lanes: 3, source: .vehicles))
        XCTAssertEqual(p.fromRight, 1)
    }

    func testOnlyRightMeansLeftmostOnlyLeftMeansRightmost() {
        var e = LanePositionEstimator()
        XCTAssertEqual(e.update(t: 0, laneOffsets: [1], lanesSame: 3).fromLeft, 0)
        var e2 = LanePositionEstimator()
        let p = e2.update(t: 0, laneOffsets: [-1, -2], lanesSame: 3)
        XCTAssertEqual(p.fromLeft, 2)
        XCTAssertEqual(p.fromRight, 0)
    }

    func testMemoryAndLaneChange() {
        var e = LanePositionEstimator()
        _ = e.update(t: 0, laneOffsets: [-1], lanesSame: 3)
        // xe bên trái khuất khỏi hình nhưng vẫn nhớ; thấy thêm xe bên phải → làn giữa
        XCTAssertEqual(e.update(t: 2, laneOffsets: [1], lanesSame: 3).fromLeft, 1)
        // đổi sang làn trái: xe bên trái (1 làn) giờ là làn mình → quên; xe bên phải cách 2 làn
        e.laneChanged(-1)
        XCTAssertEqual(e.update(t: 3, laneOffsets: [], lanesSame: 3).fromLeft, 0)
        // quá 6 s không thấy ai: về GPS / mặc định
        XCTAssertEqual(e.update(t: 10, laneOffsets: [], lanesSame: 3, gpsFromRight: 0).source, .gps)
        XCTAssertEqual(e.update(t: 10, laneOffsets: [], lanesSame: 3, gpsFromRight: 0).fromLeft, 2)
        XCTAssertEqual(e.update(t: 10, laneOffsets: [], lanesSame: 3).source, .none)
    }

    func testCameraBeatsWrongOsmAndOncoming() {
        var e = LanePositionEstimator()
        // OSM nói 2 làn nhưng thấy xe ở 2 làn bên trái và 1 làn bên phải: ít nhất 4 làn
        let p = e.update(t: 0, laneOffsets: [-2, 1], lanesSame: 2)
        XCTAssertEqual(p.lanes, 4)
        XCTAssertEqual(p.fromLeft, 2)
        // đường hai chiều, xe ngược chiều ngay bên kia vạch giữa: làn sát vạch giữa
        var e2 = LanePositionEstimator()
        XCTAssertEqual(e2.update(t: 0, laneOffsets: [1], oncomingLanesLeft: 1, lanesSame: 2).source, .oncoming)
    }
}

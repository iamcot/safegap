import XCTest
@testable import SafeGapCore

final class OncomingTests: XCTestCase {
    /// 15 fps, khoảng cách theo thời gian + nhiễu ±5% xen kẽ (giống sai số bề rộng box).
    func run(_ c: OncomingClassifier, own: Double?, lateral: Double, d0: Double, rate: Double, frames: Int = 20) -> Set<Int> {
        var out = Set<Int>()
        for i in 0..<frames {
            let t = Double(i) / 15
            let d = (d0 - rate * t) * (i % 2 == 0 ? 1.05 : 0.95)
            out = c.update(t: t, ownSpeedMps: own, laneHalfWidth: 1.75,
                           observations: [.init(id: 7, distance: d, lateral: lateral)])
        }
        return out
    }

    func testOncomingOnLeftDetected() {
        // mình 40 km/h (11 m/s), xe kia 40 km/h ngược chiều: lại gần 22 m/s, ở làn trái
        XCTAssertEqual(run(OncomingClassifier(), own: 11, lateral: -3.5, d0: 50, rate: 22), [7])
    }

    func testSameDirectionNotOncoming() {
        // xe cùng chiều chạy chậm hơn mình 3 m/s
        XCTAssertTrue(run(OncomingClassifier(), own: 11, lateral: -3.5, d0: 30, rate: 3).isEmpty)
    }

    func testFastClosingButInMyLaneNotOncoming() {
        // xe trước phanh gấp trong làn mình: không coi là ngược chiều (để vẫn cảnh báo)
        XCTAssertTrue(run(OncomingClassifier(), own: 11, lateral: 0.2, d0: 40, rate: 22).isEmpty)
    }

    func testNoSpeedUsesAbsoluteThreshold() {
        XCTAssertEqual(run(OncomingClassifier(), own: nil, lateral: -3.5, d0: 50, rate: 12), [7])
        XCTAssertTrue(run(OncomingClassifier(), own: nil, lateral: -3.5, d0: 50, rate: 2).isEmpty)
    }

    func testPipelineExcludesTrackFromEgo() {
        let cfg = AppConfig(camera: CameraConfig(fPx: 1400, fPxImageWidth: 1920, hCamM: 1.2),
                            vehicleWidthM: ["car": 1.8],
                            roi: RoiConfig(polygon: [Point(0, 0), Point(1, 0), Point(1, 1), Point(0, 1)]))
        let p = Pipeline(config: cfg, law: LawConfig(table: [.init(maxKmh: 200, dMinM: 35)]), frameWidth: 1920, frameHeight: 1080)
        let det = Detection(900, 500, 1000, 560, "car")
        let r1 = p.step(frame: 0, t: 0, speedKmh: 40, detections: [det])
        XCTAssertEqual(r1.trackIds.count, 1)
        let id = r1.trackIds[0]!
        XCTAssertEqual(r1.trackId, id)
        p.excludedTracks = [id]
        let r2 = p.step(frame: 1, t: 0.07, speedKmh: 40, detections: [det])
        XCTAssertNil(r2.trackId)
        XCTAssertNil(r2.d)
        XCTAssertEqual(r2.trackIds, [id])
    }
}

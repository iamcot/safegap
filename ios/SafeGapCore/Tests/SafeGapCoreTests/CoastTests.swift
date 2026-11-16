import XCTest
@testable import SafeGapCore

final class CoastTests: XCTestCase {
    func pipeline(coast: Double) -> Pipeline {
        let cfg = AppConfig(camera: CameraConfig(fPx: 1400, fPxImageWidth: 1920, hCamM: 1.2),
                            vehicleWidthM: ["car": 1.8],
                            roi: RoiConfig(polygon: [Point(0, 0), Point(1, 0), Point(1, 1), Point(0, 1)]))
        let p = Pipeline(config: cfg, law: LawConfig(table: [.init(maxKmh: 200, dMinM: 35)]), frameWidth: 1920, frameHeight: 1080)
        p.coastS = coast
        return p
    }

    func testCoastKeepsLeadCarThroughShortMiss() throws {
        let p = pipeline(coast: 0.5)
        let det = Detection(900, 500, 1000, 560, "car")
        var last: FrameResult?
        for i in 0..<5 { last = p.step(frame: i, t: Double(i) / 15, speedKmh: 30, detections: [det]) }
        let id = try XCTUnwrap(last?.trackId)
        let d0 = try XCTUnwrap(last?.d)
        // 3 frame (0,2 s) model không thấy xe: vẫn giữ, D gần như cũ
        for i in 5..<8 {
            let r = p.step(frame: i, t: Double(i) / 15, speedKmh: 30, detections: [])
            XCTAssertEqual(r.trackId, id)
            XCTAssertEqual(try XCTUnwrap(r.d), d0, accuracy: 2)
            XCTAssertNil(r.dRaw)
        }
        // thấy lại: cùng track
        XCTAssertEqual(p.step(frame: 8, t: 8.0 / 15, speedKmh: 30, detections: [det]).trackId, id)
        // mất lâu hơn 0,5 s: bỏ
        var r = FrameResult(frame: 0, t: 0, speedKmh: nil)
        for i in 9..<20 { r = p.step(frame: i, t: Double(i) / 15, speedKmh: 30, detections: []) }
        XCTAssertNil(r.d)
    }

    func testNoCoastByDefault() {
        let p = pipeline(coast: 0)
        let det = Detection(900, 500, 1000, 560, "car")
        for i in 0..<5 { p.step(frame: i, t: Double(i) / 15, speedKmh: 30, detections: [det]) }
        XCTAssertNil(p.step(frame: 5, t: 5.0 / 15, speedKmh: 30, detections: []).d)
    }
}

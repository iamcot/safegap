@testable import SafeGapCore
import XCTest

final class LightGroupTests: XCTestCase {
    func testMotorcycleLightBelowOnSamePoleDropped() {
        let main = Detection(1000, 100, 1030, 180, "traffic light")
        let moto = Detection(1002, 260, 1028, 330, "traffic light")   // cùng cột, thấp hẳn
        let other = Detection(600, 120, 625, 190, "traffic light")    // cột khác
        XCTAssertEqual(LightGroup.dropLow([main, moto, other]), [main, other])
    }

    func testArrowRowWithMixedColorsIsUnknown() {
        let left = Detection(900, 100, 930, 180, "traffic light")
        let straight = Detection(950, 100, 980, 180, "traffic light")
        XCTAssertEqual(LightGroup.color(of: straight, colors: [(left, .green), (straight, .red)]), .unknown)
        // cùng màu cả dãy: giữ màu
        XCTAssertEqual(LightGroup.color(of: straight, colors: [(left, .red), (straight, .red)]), .red)
        // đèn khác ở xa (ngã tư kế) không tính
        let far = Detection(200, 400, 210, 420, "traffic light")
        XCTAssertEqual(LightGroup.color(of: straight, colors: [(far, .green), (straight, .red)]), .red)
    }
}

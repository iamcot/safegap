import XCTest
@testable import SafeGapCore

final class HorizonTests: XCTestCase {
    func testLevelCameraHasHorizonAtCenter() {
        // máy dựng đứng, cầm ngang: trọng lực theo trục X của máy
        let p = Horizon.cameraPitch(gravityX: -1, gravityY: 0, gravityZ: 0)!
        XCTAssertEqual(p, 0, accuracy: 1e-12)
        XCTAssertEqual(Horizon.yPx(fPx: 1450, cy: 540, pitchRad: p), 540, accuracy: 1e-9)
    }

    func testTiltBackRaisesCameraAndLowersHorizon() {
        // ngả đầu máy ra sau 5°: trọng lực có thành phần +Z (màn hình hơi úp xuống)
        let a = 5.0 * .pi / 180
        let p = Horizon.cameraPitch(gravityX: -cos(a), gravityY: 0, gravityZ: sin(a))!
        XCTAssertEqual(p, a, accuracy: 1e-12)
        let y = Horizon.yPx(fPx: 1450, cy: 540, pitchRad: p)
        XCTAssertEqual(y, 540 + 1450 * tan(a), accuracy: 1e-9)
        XCTAssertEqual(Horizon.pitch(yHorizonPx: y, fPx: 1450, cy: 540), a, accuracy: 1e-12)
    }

    func testGroundDistanceWithPitch() {
        // xe cách 20 m, camera cao 1.2 m, ngẩng 2°: đáy xe ở góc atan(1.2/20) dưới phương ngang
        let f = 1450.0, cy = 540.0, pitch = 2.0 * .pi / 180
        let yBottom = cy + f * tan(atan(1.2 / 20) + pitch)
        let yH = Horizon.yPx(fPx: f, cy: cy, pitchRad: pitch)
        let d = Distance.fromGround(fPx: f, hCamM: 1.2, yBottomPx: yBottom, yHorizonPx: yH)!
        XCTAssertEqual(d, 20, accuracy: 0.3)   // công thức xấp xỉ, sai < 2% ở góc nhỏ
        // không bù pitch (coi chân trời ở giữa ảnh) thì sai nhiều
        let dNoComp = Distance.fromGround(fPx: f, hCamM: 1.2, yBottomPx: yBottom, yHorizonPx: cy)!
        XCTAssertLessThan(dNoComp, 14)
    }

    func testNoGravity() {
        XCTAssertNil(Horizon.cameraPitch(gravityX: 0, gravityY: 0, gravityZ: 0))
    }
}

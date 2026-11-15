import XCTest
@testable import SafeGapCore

final class ThermalTests: XCTestCase {
    func count(fpsIn: Double, target: Double, seconds: Double = 10) -> Int {
        var th = FrameThrottle()
        var n = 0
        let frames = Int(fpsIn * seconds)
        for i in 0..<frames where th.shouldProcess(t: Double(i) / fpsIn, targetFps: target) { n += 1 }
        return n
    }

    func testNominalKeepsAllFrames() {
        XCTAssertEqual(count(fpsIn: 30, target: 30), 300)
    }

    func testThrottledRates() {
        XCTAssertEqual(Double(count(fpsIn: 30, target: 12)), 120, accuracy: 25)  // khung 30 fps: được 10–15 fps
        XCTAssertEqual(Double(count(fpsIn: 30, target: 6)), 60, accuracy: 6)
        XCTAssertLessThan(count(fpsIn: 30, target: 20), 300)
    }

    func testJitterDoesNotDropAtFullRate() {
        var th = FrameThrottle()
        var n = 0
        for i in 0..<300 {
            let jitter = (i % 2 == 0 ? 0.004 : -0.004)
            if th.shouldProcess(t: Double(i) / 30 + jitter, targetFps: 30) { n += 1 }
        }
        XCTAssertEqual(n, 300)
    }

    func testTimeGoingBackwardsProcesses() {
        var th = FrameThrottle()
        XCTAssertTrue(th.shouldProcess(t: 10, targetFps: 6))
        XCTAssertTrue(th.shouldProcess(t: 1, targetFps: 6))  // camera khởi động lại
    }

    func testPolicy() {
        let p = ThermalPolicy()
        XCTAssertEqual(ThermalLevel.allCases.map(p.targetFps), [30, 20, 12, 6])
    }
}

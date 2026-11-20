@testable import SafeGapCore
import XCTest

final class SideVehicleTests: XCTestCase {
    func testOvertakenCarKeepsSlidingBack() {
        var m = SideVehicleMemory()
        // xe bên phải, mình nhanh hơn 5 m/s: z giảm dần
        for i in 0...10 {
            let t = Double(i) * 0.1
            XCTAssertEqual(m.update(t: t, seen: [SideVehicle(id: 7, lane: 1, z: 8 - 5 * t, cls: "car")]), [])
        }
        // ra khỏi khung hình ở z = 3: tiếp tục tụt ra sau
        let a = m.update(t: 1.5, seen: [])
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].lane, 1)
        XCTAssertLessThan(a[0].z, 3)
        // tụt quá xa ra sau thì bỏ
        XCTAssertEqual(m.update(t: 4.9, seen: []), [])
    }

    func testFarOrOwnLaneOrPullingAwayNotRemembered() {
        var m = SideVehicleMemory()
        _ = m.update(t: 0, seen: [SideVehicle(id: 1, lane: -1, z: 30, cls: "car"),
                                  SideVehicle(id: 2, lane: 0, z: 6, cls: "car")])
        XCTAssertEqual(m.update(t: 0.2, seen: []), [])
        // xe chạy xa dần (nhanh hơn mình) mà mất dấu: không đoán nó lùi lại
        var m2 = SideVehicleMemory()
        _ = m2.update(t: 0, seen: [SideVehicle(id: 3, lane: 1, z: 6, cls: "car")])
        _ = m2.update(t: 0.5, seen: [SideVehicle(id: 3, lane: 1, z: 8, cls: "car")])
        let out = m2.update(t: 1.0, seen: [])
        XCTAssertEqual(out.first?.z ?? 0, 8, accuracy: 0.001)
        XCTAssertEqual(m2.update(t: 5.0, seen: []), [])  // quá holdS
    }

    func testLaneChangeShiftsMemory() {
        var m = SideVehicleMemory()
        _ = m.update(t: 0, seen: [SideVehicle(id: 4, lane: -1, z: 4, cls: "truck")])
        m.laneChanged(1)   // mình sang phải: xe đó giờ cách 2 làn bên trái
        XCTAssertEqual(m.update(t: 0.3, seen: []).first?.lane, -2)
    }
}

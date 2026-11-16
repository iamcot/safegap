// Test viết tay, giống tests/test_core.py, cộng phần riêng của app (hiệu chỉnh theo máy, CSV).
import XCTest
@testable import SafeGapCore

final class CoreTests: XCTestCase {
    static let defaultJSON = """
    {
      "camera": {"f_px": 1530.0, "f_px_image_width": 2100, "h_cam_m": 1.2},
      "vehicle_width_m": {"car": 1.80, "truck": 2.50, "bus": 2.50},
      "detection": {"model": "yolo11n.pt", "classes": ["car", "truck", "bus"], "min_conf": 0.35,
                    "max_width_ratio": 0.7, "max_bottom_ratio": 0.97},
      "roi": {"comment": "x", "polygon": [[0.42, 0.45], [0.58, 0.45], [0.80, 1.0], [0.20, 1.0]]},
      "distance": {"use_ground": false, "y_horizon_norm": 0.45, "fuse_far_m": 40.0},
      "tracker": {"iou_match": 0.3, "max_missed": 10, "accel_sigma": 3.0, "meas_rel_sigma": 0.08},
      "alert": {"red_ratio": 0.9, "yellow_ratio": 1.1, "hold_s": 1.0, "min_speed_kmh": 40.0,
                "sound_cooldown_s": 5.0, "manual_d_min_m": null}
    }
    """
    static let lawJSON = """
    {"source": "TT38", "table": [{"max_kmh": 60, "d_min_m": 35}, {"max_kmh": 80, "d_min_m": 55},
     {"max_kmh": 100, "d_min_m": 70}, {"max_kmh": 120, "d_min_m": 100}]}
    """

    var cfg: AppConfig { try! AppConfig.decode(Data(Self.defaultJSON.utf8)) }
    var law: LawConfig { try! LawConfig.decode(Data(Self.lawJSON.utf8)) }

    func testDecodeConfig() {
        let c = cfg
        XCTAssertEqual(c.camera.fPx, 1530)
        XCTAssertEqual(c.camera.fPxImageWidth, 2100)
        XCTAssertEqual(c.vehicleWidthM["truck"], 2.5)
        XCTAssertEqual(c.detection.maxWidthRatio, 0.7)
        XCTAssertEqual(c.roi.polygon[2], Point(0.8, 1.0))
        XCTAssertNil(c.alert.manualDMinM)
        XCTAssertEqual(law.table.count, 4)
    }

    func testDecodeConfigDefaults() throws {
        let minimal = """
        {"camera": {"f_px": 1000, "f_px_image_width": 1920}, "vehicle_width_m": {"car": 1.8},
         "roi": {"polygon": [[0.4, 0.5], [0.6, 0.5], [0.8, 1], [0.2, 1]]}}
        """
        let c = try AppConfig.decode(Data(minimal.utf8))
        XCTAssertEqual(c.detection.maxBottomRatio, 0.97)
        XCTAssertEqual(c.alert.holdS, 1.0)
        XCTAssertEqual(c.tracker.maxMissed, 10)
        XCTAssertEqual(c.camera.hCamM, 1.2)
    }

    func testFocalLength() {
        XCTAssertEqual(FocalLength.fromReference(wPx: 151.47, distanceM: 3)!, 1530, accuracy: 1.6)
        let f = FocalLength.fromHFOV(imageWidthPx: 1920, hfovDeg: 70)!
        XCTAssertEqual(FocalLength.hfovDeg(fPx: f, imageWidthPx: 1920), 70, accuracy: 1e-9)
        XCTAssertNil(FocalLength.fromReference(wPx: 0, distanceM: 3))
        XCTAssertNil(FocalLength.fromHFOV(imageWidthPx: 1920, hfovDeg: 180))
    }

    func testMazdaReferencePhoto() {
        // SafeGap.md mục 9: Mazda6 ~10 m, f ≈ 1530, xe rộng 1.8 m → ~275 px
        XCTAssertEqual(Distance.fromWidth(fPx: 1530, wRealM: 1.8, wPx: 275.4)!, 10.0, accuracy: 0.1)
    }

    func testOwnVehicleHoodIsIgnored() {
        let p = Pipeline(config: cfg, law: law, frameWidth: 1920, frameHeight: 1080)
        XCTAssertFalse(p.keeps(Detection(100, 900, 1820, 1080, "car")))  // capo: rộng + chạm đáy
        XCTAssertFalse(p.keeps(Detection(200, 600, 1700, 1000, "car")))  // rộng > 0.7 khung
        XCTAssertFalse(p.keeps(Detection(800, 900, 1100, 1060, "car")))  // đáy dưới 0.97 khung
        XCTAssertFalse(p.keeps(Detection(900, 600, 950, 700, "motorcycle")))
        XCTAssertTrue(p.keeps(Detection(860, 600, 1060, 760, "car")))
        // capo là box "gần nhất" trong ROI, nhưng bị bỏ nên xe phía trước vẫn được đo
        let front = Detection(900, 560, 1000, 640, "car")
        let r = p.step(frame: 0, t: 0, speedKmh: 90, detections: [Detection(100, 900, 1820, 1080, "car"), front])
        XCTAssertEqual(r.egoBox, front.box)
    }

    func testPipelineEndToEndRed() {
        // giống test_pipeline_end_to_end_red trong tests/test_core.py
        let p = Pipeline(config: cfg, law: law, frameWidth: 2100, frameHeight: 1181)
        let w = 1530 * 1.8 / 40
        let box = Detection(1050 - w / 2, 700, 1050 + w / 2, 760, "car")
        let res = (0..<45).map { p.step(frame: $0, t: Double($0) / 30, speedKmh: 100, detections: [box]) }
        XCTAssertEqual(res[0].d!, 40, accuracy: 0.04)
        XCTAssertEqual(res.last!.level, .red)
        XCTAssertEqual(res.last!.dMin, 70)
        XCTAssertEqual(res.filter(\.sound).count, 1)
    }

    func testDeviceCalibrationResolveF() {
        var cal = DeviceCalibration.defaults(from: cfg, deviceModel: "iPhone15,2", lens: "wide1x", frameWidth: 1920, frameHeight: 1080)
        XCTAssertEqual(cal.storageKey, "calib.iPhone15,2.wide1x.1920x1080")
        XCTAssertEqual(cal.resolveF(frameWidth: 1920, intrinsicsFx: 1450, hfovF: 1400, config: cfg).source, .intrinsics)
        XCTAssertEqual(cal.resolveF(frameWidth: 1920, intrinsicsFx: nil, hfovF: 1400, config: cfg).f, 1400)
        let c = cal.resolveF(frameWidth: 2100, intrinsicsFx: nil, hfovF: nil, config: cfg)
        XCTAssertEqual(c.source, .config)
        XCTAssertEqual(c.f, 1530, accuracy: 1e-9)
        cal.manualFPx = 1500
        let m = cal.resolveF(frameWidth: 960, intrinsicsFx: 1450, hfovF: nil, config: cfg)
        XCTAssertEqual(m.source, .manual)
        XCTAssertEqual(m.f, 750, accuracy: 1e-9)
    }

    func testDeviceCalibrationApply() {
        var cal = DeviceCalibration.defaults(from: cfg, deviceModel: "x", lens: "wide1x", frameWidth: 1920, frameHeight: 1080)
        cal.roi = [Point(0.45, 0.5), Point(0.55, 0.5), Point(0.7, 0.9), Point(0.3, 0.9)]
        cal.maxBottomRatio = 0.85
        let c = cal.apply(to: cfg, fPx: 1450, frameWidth: 1920)
        let p = Pipeline(config: c, law: law, frameWidth: 1920, frameHeight: 1080)
        XCTAssertEqual(p.fPx, 1450, accuracy: 1e-9)
        XCTAssertEqual(p.roi[0], Point(0.45 * 1920, 0.5 * 1080))
        XCTAssertFalse(p.keeps(Detection(900, 800, 1000, 950, "car")))  // đáy 950 > 0.85*1080
    }

    func testCalibrationRoundTrip() throws {
        let cal = DeviceCalibration.defaults(from: cfg, deviceModel: "x", lens: "wide1x", frameWidth: 1920, frameHeight: 1080)
        let back = try JSONDecoder().decode(DeviceCalibration.self, from: JSONEncoder().encode(cal))
        XCTAssertEqual(back, cal)
    }

    func testFrameLogRow() {
        var r = FrameResult(frame: 3, t: 0.1, speedKmh: 92.5)
        r.cls = "car"; r.wPx = 68.85; r.dRaw = 40.0; r.d = 40.0; r.dMin = 70; r.level = .red; r.sound = true; r.trackId = 1
        let e = FrameLog.Extra(time: "2026-11-15T10:00:00.000Z", fPx: 1450, fSource: .intrinsics, nDets: 2, inferMs: 21.3,
                               speedAccuracyKmh: nil)
        let row = FrameLog.row(r, e)
        XCTAssertEqual(row, "3,0.1000,92.50,car,68.85,40.000,40.000,70.0,RED,True,1,2026-11-15T10:00:00.000Z,1450.00,intrinsics,2,21.3,,nominal,,,")
        XCTAssertEqual(row.split(separator: ",", omittingEmptySubsequences: false).count,
                       FrameLog.header.split(separator: ",").count)
        let empty = FrameLog.row(FrameResult(frame: 0, t: 0, speedKmh: nil), e)
        XCTAssertTrue(empty.hasPrefix("0,0.0000,,,,,,,NONE,False,,"))
    }
}

final class ZoomTests: XCTestCase {
    func testZoomAdjusted() {
        XCTAssertEqual(FocalLength.zoomAdjusted(fx: 1450, zoom: 1, baseF: 1400), 1450)
        XCTAssertEqual(FocalLength.zoomAdjusted(fx: 1450, zoom: 2, baseF: 1400), 2900)   // iOS chưa nhân zoom
        XCTAssertEqual(FocalLength.zoomAdjusted(fx: 2890, zoom: 2, baseF: 1400), 2890)   // đã nhân sẵn
        XCTAssertEqual(FocalLength.zoomAdjusted(fx: 1450, zoom: 2, baseF: nil), 1450)
    }
}

final class ZoomCalibrationTests: XCTestCase {
    func testConvert1xTo2xAndBack() {
        let cal = DeviceCalibration(deviceModel: "x", lens: "wide1x", frameWidth: 1920, frameHeight: 1080, manualFPx: 1450,
                                    roi: [Point(0.42, 0.45), Point(0.58, 0.45), Point(0.80, 1.0), Point(0.20, 1.0)],
                                    maxWidthRatio: 0.7, maxBottomRatio: 0.97, hCamM: 1.3)
        var cal1 = cal
        cal1.a4LeftPx = 900
        cal1.a4RightPx = 1060
        let z = cal1.converted(zoomRatio: 2, lens: "wide2x")
        XCTAssertEqual(z.a4LeftPx, 840)
        XCTAssertEqual(z.a4RightPx, 1160)
        XCTAssertEqual(z.storageKey, "calib.x.wide2x.1920x1080")
        XCTAssertEqual(z.manualFPx, 2900)
        XCTAssertEqual(z.hCamM, 1.3)
        XCTAssertEqual(z.roi[0].x, 0.34, accuracy: 1e-9)
        XCTAssertEqual(z.roi[0].y, 0.40, accuracy: 1e-9)
        // cạnh trái 2x: từ (0.34, 0.40) tới (-0.1, 1.5) → cắt ở y = 1
        XCTAssertEqual(z.roi[3].y, 1.0, accuracy: 1e-12)
        XCTAssertEqual(z.roi[3].x, 0.34 + (-0.1 - 0.34) * 0.6 / 1.1, accuracy: 1e-9)
        XCTAssertEqual(z.maxBottomRatio, 1.0)
        let back = z.converted(zoomRatio: 0.5, lens: "wide1x")
        XCTAssertEqual(back.roi[0].x, 0.42, accuracy: 1e-9)
        XCTAssertEqual(back.manualFPx, 1450)
    }
}

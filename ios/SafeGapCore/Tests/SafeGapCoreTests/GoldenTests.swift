// So output Swift với output Python trên cùng input (Fixtures/golden.json).
import XCTest
@testable import SafeGapCore

func assertClose(_ a: Double?, _ b: Double?, rel: Double = 1e-9, _ msg: @autoclosure () -> String = "",
                 file: StaticString = #filePath, line: UInt = #line) {
    switch (a, b) {
    case (nil, nil): return
    case let (x?, y?):
        let tol = max(1e-9, rel * max(abs(x), abs(y)))
        XCTAssertLessThanOrEqual(abs(x - y), tol, "\(x) != \(y) \(msg())", file: file, line: line)
    default:
        XCTFail("\(String(describing: a)) != \(String(describing: b)) \(msg())", file: file, line: line)
    }
}

final class GoldenTests: XCTestCase {
    static var golden: Golden!

    override class func setUp() {
        super.setUp()
        golden = try! Golden.load()
    }

    var g: Golden { Self.golden }

    func testLawTable() {
        let t = LawTable(g.law)
        for c in g.lawCases { XCTAssertEqual(t.dMin(speedKmh: c.v), c.dMin, "v=\(c.v)") }
    }

    func testClassify() {
        for c in g.classify { XCTAssertEqual(classify(distanceM: c.d, dMinM: c.dMin), c.level, "d=\(c.d)") }
    }

    func testDistance() {
        for c in g.distance.fromWidth { assertClose(Distance.fromWidth(fPx: c.f, wRealM: c.wReal, wPx: c.wPx), c.d) }
        for c in g.distance.fromGround {
            assertClose(Distance.fromGround(fPx: c.f, hCamM: c.h, yBottomPx: c.yBottom, yHorizonPx: c.yHorizon), c.d)
        }
        for c in g.distance.fuse { assertClose(Distance.fuse(dWidth: c.dWidth, dGround: c.dGround, farM: c.far), c.d) }
        for c in g.distance.scaleF { assertClose(Distance.scaleFToFrame(fPx: c.f, fImageWidth: c.from, frameWidth: c.to), c.d) }
    }

    func testLane() {
        let roi = Lane.roiToPixels(g.lane.roiNorm, width: g.lane.frameW, height: g.lane.frameH)
        for c in g.lane.pointInPolygon { XCTAssertEqual(Lane.pointInPolygon(c.x, c.y, roi), c.inside, "(\(c.x), \(c.y))") }
        for (k, c) in g.lane.selectEgo.enumerated() {
            XCTAssertEqual(Lane.selectEgo(c.dets.map(\.det), roi: roi), c.ego, "case \(k)")
        }
    }

    func testIoU() {
        for c in g.iou {
            assertClose(iou(Box(c.a[0], c.a[1], c.a[2], c.a[3]), Box(c.b[0], c.b[1], c.b[2], c.b[3])), c.iou)
        }
    }

    func testKalman() {
        let k = g.kalman
        var kf = Kalman1D(d0: k.d0, accelSigma: k.accelSigma, measRelSigma: k.measRelSigma)
        for (i, s) in k.steps.enumerated() {
            kf.predict(dt: s.dt)
            kf.update(z: s.z)
            assertClose(kf.distance, s.d, rel: 1e-9, "step \(i) d")
            assertClose(kf.rate, s.rate, rel: 1e-7, "step \(i) rate")
        }
    }

    func testTracker() {
        let tr = IoUTracker(iouMatch: g.tracker.iouMatch, maxMissed: g.tracker.maxMissed)
        for (i, s) in g.tracker.steps.enumerated() {
            let ids = tr.update(boxes: s.boxes.map(\.det.box), classes: s.boxes.map(\.det.cls))
            XCTAssertEqual(ids, s.ids, "step \(i)")
            XCTAssertEqual(tr.tracks.keys.sorted(), s.alive, "step \(i) alive")
        }
    }

    func testAlertSequences() {
        for c in g.alert {
            let a = AlertState(law: LawTable(g.law), config: c.alert)
            for (i, s) in c.steps.enumerated() {
                let (lv, snd) = a.update(t: s.t, speedKmh: s.v, distanceM: s.d)
                XCTAssertEqual(lv, s.level, "\(c.name) step \(i)")
                XCTAssertEqual(snd, s.sound, "\(c.name) step \(i) sound")
                assertClose(a.dMin, s.dMin, "\(c.name) step \(i) d_min")
            }
        }
    }

    func testPipelineMatchesPython() {
        XCTAssertFalse(g.pipeline.isEmpty)
        for c in g.pipeline {
            let p = Pipeline(config: c.config, law: g.law, frameWidth: c.frameW, frameHeight: c.frameH)
            assertClose(p.fPx, c.fPx)
            for f in c.frames {
                let r = p.step(frame: f.frame, t: f.t, speedKmh: f.speedKmh, detections: f.dets.map(\.det))
                let o = f.out
                let tag = "\(c.name) frame \(f.frame)"
                XCTAssertEqual(r.frame, o.frame, tag)
                XCTAssertEqual(r.cls, o.cls, tag)
                XCTAssertEqual(r.trackId, o.trackId, tag)
                XCTAssertEqual(r.level, o.level, tag)
                XCTAssertEqual(r.sound, o.sound, tag)
                assertClose(r.t, o.t, tag)
                assertClose(r.speedKmh, o.speedKmh, tag)
                assertClose(r.wPx, o.wPx, tag)
                assertClose(r.dRaw, o.dRaw, tag)
                assertClose(r.d, o.d, rel: 1e-8, tag)
                assertClose(r.dMin, o.dMin, tag)
            }
        }
    }
}

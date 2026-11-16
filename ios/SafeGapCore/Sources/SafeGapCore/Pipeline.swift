// Ghép các bước cho 1 frame: lọc capo → tracker → chọn xe cùng làn → D → Kalman → cảnh báo.
// Port 1-1 từ proto/pipeline.py; test so khớp output với Python bằng Fixtures/golden.json.
import Foundation

public struct FrameResult: Equatable, Sendable {
    public var frame: Int
    public var t: Double
    public var speedKmh: Double?
    public var cls: String?
    public var wPx: Double?
    public var dRaw: Double?
    public var d: Double?
    public var dMin: Double?
    public var level: Level = .none
    public var sound: Bool = false
    public var trackId: Int?
    /// Chỉ có ở bản Swift: box xe đang đo, để vẽ lên HUD.
    public var egoBox: Box?
    /// Chỉ có ở bản Swift: id track của từng detection đầu vào (nil = bị lọc: capo / class lạ).
    public var trackIds: [Int?] = []

    public init(frame: Int, t: Double, speedKmh: Double?) {
        self.frame = frame; self.t = t; self.speedKmh = speedKmh
    }
}

public final class Pipeline {
    public let frameWidth: Double
    public let frameHeight: Double
    /// Tiêu cự theo pixel của frame đang xử lý. App cập nhật mỗi frame nếu intrinsics thay đổi (lấy nét).
    public var fPx: Double
    public var hCam: Double
    public let widths: [String: Double]
    /// ROI theo pixel. App thay bằng ROI bám vạch làn mỗi frame nếu bật.
    public var roi: [Point]
    public let ownVehicle: OwnVehicleFilter
    public var useGround: Bool
    /// Dòng chân trời (pixel). App cập nhật mỗi frame từ pitch của CoreMotion.
    public var yHorizon: Double
    public let fuseFar: Double
    public let tracker: IoUTracker
    public let alert: AlertState
    /// Track bị loại khỏi việc chọn xe phía trước (xe ngược chiều). Rỗng thì giống hệt bản Python.
    public var excludedTracks: Set<Int> = []
    /// Chỉ có ở bản Swift: model lỡ mất xe phía trước vài frame (ban đêm hay bị) thì vẫn giữ xe đó thêm tối đa
    /// bao nhiêu giây, D dự đoán theo Kalman. 0 = tắt (giống hệt bản Python).
    public var coastS = 0.0
    private var lastEgo: (tid: Int, t: Double, box: Box, cls: String)?
    private var lastT: Double?

    public init(config cfg: AppConfig, law: LawConfig, frameWidth: Double, frameHeight: Double) {
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        fPx = Distance.scaleFToFrame(fPx: cfg.camera.fPx, fImageWidth: cfg.camera.fPxImageWidth, frameWidth: frameWidth)
        hCam = cfg.camera.hCamM
        widths = cfg.vehicleWidthM
        roi = Lane.roiToPixels(cfg.roi.polygon, width: frameWidth, height: frameHeight)
        ownVehicle = OwnVehicleFilter(maxWidthRatio: cfg.detection.maxWidthRatio, maxBottomRatio: cfg.detection.maxBottomRatio,
                                      frameWidth: frameWidth, frameHeight: frameHeight)
        useGround = cfg.distance.useGround
        yHorizon = cfg.distance.yHorizonNorm * frameHeight
        fuseFar = cfg.distance.fuseFarM
        tracker = IoUTracker(cfg.tracker)
        alert = AlertState(law: LawTable(law), config: cfg.alert)
    }

    /// Box được giữ lại để đo: class có bề rộng chuẩn và không phải capo/taplo xe mình.
    public func keeps(_ d: Detection) -> Bool {
        widths[d.cls] != nil && ownVehicle.keeps(d)
    }

    public func step(frame: Int, t: Double, speedKmh: Double?, detections: [Detection]) -> FrameResult {
        let dt = lastT.map { t - $0 } ?? 0.0
        lastT = t
        let keepMask = detections.map(keeps)
        let dets = zip(detections, keepMask).filter(\.1).map(\.0)
        let ids = tracker.update(boxes: dets.map(\.box), classes: dets.map(\.cls))
        var r = FrameResult(frame: frame, t: t, speedKmh: speedKmh)
        var next = ids.makeIterator()
        r.trackIds = keepMask.map { $0 ? next.next() : nil }
        // chọn xe phía trước, bỏ qua track bị loại (nếu có)
        let cand = dets.indices.filter { !excludedTracks.contains(ids[$0]) }
        if let c = Lane.selectEgo(cand.map { dets[$0] }, roi: roi) {
            let e = cand[c]
            let ego = dets[e]
            let tid = ids[e]
            if var dRaw = Distance.fromWidth(fPx: fPx, wRealM: widths[ego.cls]!, wPx: ego.width) {
                if useGround {
                    let g = Distance.fromGround(fPx: fPx, hCamM: hCam, yBottomPx: ego.y2, yHorizonPx: yHorizon)
                    dRaw = Distance.fuse(dWidth: dRaw, dGround: g, farM: fuseFar)
                }
                r.cls = ego.cls
                r.wPx = ego.width
                r.dRaw = dRaw
                r.trackId = tid
                r.egoBox = ego.box
                r.d = tracker.updateDistance(tid: tid, dMeas: dRaw, dt: dt)
                lastEgo = (tid, t, ego.box, ego.cls)
            }
        }
        if r.d == nil, coastS > 0, let le = lastEgo, t - le.t <= coastS, !excludedTracks.contains(le.tid),
           let tr = tracker.tracks[le.tid], tr.missed > 0, let d = tracker.coastDistance(tid: le.tid, dt: dt) {
            r.d = d
            r.cls = le.cls
            r.trackId = le.tid
            r.egoBox = le.box
        }
        let (level, sound) = alert.update(t: t, speedKmh: speedKmh, distanceM: r.d)
        r.level = level
        r.sound = sound
        r.dMin = alert.dMin
        return r
    }
}

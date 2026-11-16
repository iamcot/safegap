// Xử lý từng frame trên hàng đợi camera: f theo máy → YOLO → Pipeline (port từ Python) → âm thanh, log, HUD.
import CoreMedia
import Foundation
import QuartzCore
import SafeGapCore

/// Cài đặt người dùng (lưu UserDefaults). Đọc từng khoá, thiếu thì lấy mặc định (thêm cài đặt mới không mất cái cũ).
struct UserSettings: Codable, Equatable {
    var soundOn = true
    var logOn = true
    /// d_min chỉnh tay (biển cự ly, trời mưa). nil = theo bảng luật.
    var manualDMinM: Double?
    /// Chỉ để thử khi đứng yên. nil = dùng GPS.
    var simulatedSpeedKmh: Double?
    /// Ngưỡng tốc độ bắt đầu cảnh báo. nil = theo config (40 km/h). Hạ xuống để thử trong phố.
    var minSpeedKmh: Double?
    /// ROI bám theo vạch làn nhận diện được (tắt = dùng hình thang hiệu chỉnh cố định).
    var laneFollow = true
    /// Kết hợp cách đo theo mặt đường (cần chiều cao camera), chân trời lấy từ CoreMotion.
    var groundFusion = true
    /// Zoom 2x trên camera chính để đo xa (hiệu chỉnh lưu riêng cho chế độ này).
    var zoom2x = false
    /// Chạy mát: YOLO 15 fps (giảm tiếp khi nóng) thay vì 30.
    var coolMode = true
    /// Ẩn hình camera trên HUD (chỉ số và màu), đỡ tốn GPU vẽ hình.
    var hidePreview = true
    /// Tự tải dữ liệu đường OpenStreetMap quanh xe (số làn, một chiều) khi có mạng.
    var autoRoads = true
    /// Đọc cảnh báo bằng giọng tiếng Việt (đèn đỏ, đèn xanh...).
    var voiceOn = true
    /// Nhận đèn giao thông (bản thử: lớp "traffic light" của YOLO + màu HSV).
    var trafficLights = true

    var zoom: Double { zoom2x ? 2 : 1 }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UserSettings()
        soundOn = try c.decodeIfPresent(Bool.self, forKey: .soundOn) ?? d.soundOn
        logOn = try c.decodeIfPresent(Bool.self, forKey: .logOn) ?? d.logOn
        manualDMinM = try c.decodeIfPresent(Double.self, forKey: .manualDMinM)
        simulatedSpeedKmh = try c.decodeIfPresent(Double.self, forKey: .simulatedSpeedKmh)
        minSpeedKmh = try c.decodeIfPresent(Double.self, forKey: .minSpeedKmh)
        laneFollow = try c.decodeIfPresent(Bool.self, forKey: .laneFollow) ?? d.laneFollow
        groundFusion = try c.decodeIfPresent(Bool.self, forKey: .groundFusion) ?? d.groundFusion
        zoom2x = try c.decodeIfPresent(Bool.self, forKey: .zoom2x) ?? d.zoom2x
        coolMode = try c.decodeIfPresent(Bool.self, forKey: .coolMode) ?? d.coolMode
        hidePreview = try c.decodeIfPresent(Bool.self, forKey: .hidePreview) ?? d.hidePreview
        autoRoads = try c.decodeIfPresent(Bool.self, forKey: .autoRoads) ?? d.autoRoads
        voiceOn = try c.decodeIfPresent(Bool.self, forKey: .voiceOn) ?? d.voiceOn
        trafficLights = try c.decodeIfPresent(Bool.self, forKey: .trafficLights) ?? d.trafficLights
    }

    static let key = "settings.v1"

    static func load() -> UserSettings {
        guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(UserSettings.self, from: d) else {
            return UserSettings()
        }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

/// Kết quả 1 frame gửi lên giao diện.
struct FrameSnapshot {
    var result = FrameResult(frame: 0, t: 0, speedKmh: nil)
    var detections: [Detection] = []
    /// cùng thứ tự với detections: true = được dùng để đo (không phải capo / class lạ)
    var kept: [Bool] = []
    var frameWidth = CameraController.frameWidth
    var frameHeight = CameraController.frameHeight
    var fPx: Double = 0
    var fSource: FocalSource = .config
    var fIntrinsics: Double?
    var fHFOV: Double?
    var fps: Double = 0
    var inferMs: Double = 0
    var speedSimulated = false
    var gpsOK = false
    var detectorError: String?
    var thermal: ThermalLevel = .nominal
    var targetFps: Double = 30
    /// ROI đang dùng (chuẩn hoá): bám làn hoặc hình thang hiệu chỉnh.
    var roiNorm: [Point]?
    var laneLeft: LaneCurve?
    var laneRight: LaneCurve?
    /// Làn ổn định theo mét để vẽ màn lái.
    var roadLane = RoadLane()
    /// Cùng thứ tự với detections: true = xe ngược chiều.
    var oncoming: [Bool] = []
    /// Vạch phân cách với chiều ngược lại: 1 = mép trái làn mình, 2 = mép trái làn bên trái, ... nil = chưa thấy.
    var oncomingLane: Int?
    /// Con đường đang chạy theo OpenStreetMap (số làn mỗi chiều), nil = chưa có dữ liệu / chưa khớp.
    var road: RoadMatch?
    /// Hình dạng đường phía trước và ngã tư (OSM), đã dịch theo quãng đường đi từ lúc tra.
    var roadAhead: RoadAhead?
    /// Chân trời (pixel) và góc ngẩng (độ) từ CoreMotion; nil nếu không có.
    var yHorizon: Double?
    var pitchDeg: Double?
    /// Đèn giao thông đang áp dụng (nil = không thấy / tắt).
    var light: TrafficLightState?
    /// Khoảng cách tới ngã tư kế tiếp (OSM + quãng đường đã đi), nil = không biết.
    var junctionM: Double?
    /// Lần rẽ gần nhất và đang rẽ hay không.
    var lastTurn: TurnEvent?
    var turning: TurnDirection?
    /// Số giây đã đứng yên, nil = đang chạy.
    var stoppedS: Double?
    var t: Double = 0
}

final class FrameProcessor {
    struct Params {
        var config: AppConfig
        var law: LawConfig
        var calibration: DeviceCalibration
        var settings: UserSettings
        var version: Int
    }

    private let lock = NSLock()
    private var params: Params
    private var detector: YOLODetector?
    private var detectorError: String?
    private var pipeline: Pipeline?
    private var pipelineVersion = -1
    private var pipelineW = 0.0
    private var pipelineH = 0.0
    private var frameIndex = 0
    private var lastFrameTime: CFTimeInterval?
    private var fpsEMA = 0.0
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    let speed: SpeedProvider
    let motion: MotionProvider
    let logger: CSVLogger
    let sound: AlertSound
    let voice: VoiceAlerts
    var hfovDeg: Double?
    static func policy(_ s: UserSettings) -> ThermalPolicy { s.coolMode ? .cool : ThermalPolicy() }
    /// Lịch chạy model theo nhiệt + đứng/chạy (thay FrameThrottle; đứng yên thì xe trước còn 5 fps).
    private var scheduler = InferenceScheduler(vehicles: .cool)
    private var odometer = Odometer()
    private var stopDetector = StopDetector()
    private var turnDetector = TurnDetector()
    private var junctions = JunctionTracker()
    private var lightTracker = TrafficLightTracker()
    private let lightRules = LightAlertRules()
    static let trafficLightClass = "traffic light"
    private var thermalLevel: ThermalLevel = .nominal
    private var laneTracker = LaneTracker()
    /// Số frame liền không thấy vạch trong cửa sổ dự đoán; quá 30 thì dò lại cả ảnh.
    private var gateMisses = 0
    private let roadLane = RoadLaneFilter()
    private let oncoming = OncomingClassifier()
    /// Làn có xe ngược chiều gần nhất (1 = làn sát bên trái) và lúc thấy lần cuối, để giữ vạch vàng vài giây.
    private var oncomingLane: (index: Int, t: Double)?

    /// Gọi từ main khi iOS báo đổi mức nhiệt.
    func setThermal(_ level: ThermalLevel) {
        lock.lock()
        thermalLevel = level
        lock.unlock()
    }

    private func currentThermal() -> ThermalLevel {
        lock.lock()
        defer { lock.unlock() }
        return thermalLevel
    }
    /// Gọi trên hàng đợi camera; bên nhận tự chuyển về main.
    var onSnapshot: ((FrameSnapshot) -> Void)?

    /// Dữ liệu đường OSM (gán từ AppModel).
    var roads: RoadStore?
    private var roadMatch: (match: RoadMatch?, t: Double)?
    private var roadLookupT = -10.0
    private var roadAhead: (ahead: RoadAhead, t: Double, travelled: Double, lastT: Double)?

    init(params: Params, speed: SpeedProvider, motion: MotionProvider, logger: CSVLogger, sound: AlertSound,
         voice: VoiceAlerts) {
        self.params = params
        self.voice = voice
        self.speed = speed
        self.motion = motion
        self.logger = logger
        self.sound = sound
        do {
            detector = try YOLODetector()
        } catch {
            detectorError = error.localizedDescription
        }
    }

    func setParams(_ p: Params) {
        lock.lock()
        params = p
        lock.unlock()
    }

    private func currentParams() -> Params {
        lock.lock()
        defer { lock.unlock() }
        return params
    }

    func process(_ sb: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let w = Double(CVPixelBufferGetWidth(pb)), h = Double(CVPixelBufferGetHeight(pb))
        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        let p = currentParams()
        let thermal = currentThermal()
        let policy = Self.policy(p.settings)
        if scheduler.moving[.vehicles] != policy.fps { scheduler = InferenceScheduler(vehicles: policy) }
        let isStopped = stopDetector.isStopped
        let targetFps = scheduler.targetFps(.vehicles, thermal: thermal, isStopped: isStopped)
        // Máy nóng / đứng yên: bỏ bớt frame (YOLO là phần tốn pin / nhiệt nhất). Kalman dùng dt thật nên vẫn đúng.
        guard scheduler.shouldRun(.vehicles, t: t, thermal: thermal, isStopped: isStopped) else { return }

        let intr = CameraController.intrinsics(sb)
        // HFOV của định dạng là ở 1x; khi zoom thì f tăng theo zoom
        let zoom = p.settings.zoom
        let baseF = hfovDeg.flatMap { FocalLength.fromHFOV(imageWidthPx: w, hfovDeg: $0) }
        let fx = intr.map { FocalLength.zoomAdjusted(fx: $0.fx, zoom: zoom, baseF: baseF) }
        let hfovF = baseF.map { $0 * zoom }
        let (f, source) = p.calibration.resolveF(frameWidth: w, intrinsicsFx: fx, hfovF: hfovF, config: p.config)

        if pipeline == nil || pipelineVersion != p.version || pipelineW != w || pipelineH != h {
            var cfg = p.calibration.apply(to: p.config, fPx: f, frameWidth: w)
            cfg.alert.manualDMinM = p.settings.manualDMinM
            if let m = p.settings.minSpeedKmh { cfg.alert.minSpeedKmh = m }
            pipeline = Pipeline(config: cfg, law: p.law, frameWidth: w, frameHeight: h)
            pipeline?.coastS = 0.5
            pipelineVersion = p.version
            pipelineW = w
            pipelineH = h
        }
        guard let pipeline else { return }
        pipeline.fPx = f

        // Bù pitch: chân trời theo góc ngẩng thật của camera, rồi mới dùng cách đo theo mặt đường.
        var yHorizon: Double?, pitchDeg: Double?
        if let pitch = motion.currentPitch() {
            let pc = pitch + (p.calibration.pitchOffsetDeg ?? 0) * .pi / 180
            yHorizon = Horizon.yPx(fPx: f, cy: intr?.cy ?? h / 2, pitchRad: pc)
            pitchDeg = pc * 180 / .pi
        }
        pipeline.useGround = p.settings.groundFusion && yHorizon != nil
        if let yHorizon { pipeline.yHorizon = yHorizon }

        // Dò vạch làn (Phase 3). Chỉ tìm ở đoạn đường gần ngay trước xe (≤ 25 m); khi đã có làn ổn định thì
        // mỗi hàng chỉ nhận vệt sáng sát vị trí vạch dự đoán (± 0,45 m), không nhảy sang xe / đèn / vạch làn khác.
        let yH = yHorizon ?? p.config.distance.yHorizonNorm * h
        let hCam = p.calibration.hCamM
        if p.settings.laneFollow, let gray = Self.gray(pb) {
            let cal = p.calibration
            let top = cal.roi.map(\.y).min() ?? 0.45
            var lc = LaneConfig()
            lc.yBottom = min(0.95, cal.maxBottomRatio - 0.02)
            lc.yTop = top + 0.25 * (lc.yBottom - top)
            if f > 0 { lc.yTop = max(lc.yTop, min(lc.yBottom - 0.12, (yH + f * hCam / 25) / h)) }
            let (tl, tr) = (laneTracker.left, laneTracker.right)
            let prev = roadLane.lane
            var gate: ((Double) -> (left: Double, right: Double, tol: Double))?
            if prev.tracked, gateMisses < 30, f > 0 {
                gate = { yn in
                    let dy = yn * h - yH
                    guard dy > 1 else { return (-1, -1, 0) }
                    let z = f * hCam / dy
                    return ((prev.left(z) * f / z + w / 2) / w, (prev.right(z) * f / z + w / 2) / w,
                            max(0.012, 0.45 * f / z / w))
                }
            }
            let d = LaneDetector.detect(gray, config: lc, center: { y in
                LaneROI.center(at: y, left: tl, right: tr, calibrated: cal.roi)
            }, gate: gate)
            let found = d.left != nil || d.right != nil
            if found { gateMisses = 0 } else if gate != nil { gateMisses += 1 }
            laneTracker.update(d)
        } else {
            laneTracker.reset()
        }

        // Mô hình làn ổn định (mét): chiếu vạch xuống mặt đường, lọc chậm.
        func ground(_ c: LaneCurve?) -> [(x: Double, z: Double)]? {
            guard let c, f > 0 else { return nil }
            return stride(from: 0.5, through: 1.0, by: 0.02).compactMap { yn -> (x: Double, z: Double)? in
                let dy = yn * h - yH
                guard dy > 1 else { return nil }
                let z = f * p.calibration.hCamM / dy
                return ((c.x(at: yn) * w - w / 2) * z / f, z)
            }
        }
        let road = roadLane.update(left: ground(laneTracker.left), right: ground(laneTracker.right))
        // Vạch vẽ trên ảnh và ROI theo làn ổn định (không theo vạch thô từng frame).
        var stableL: LaneCurve?, stableR: LaneCurve?
        if p.settings.laneFollow, road.tracked {
            stableL = road.imageCurve(side: -1, fPx: f, hCamM: hCam, yHorizonPx: yH, imageWidth: w, imageHeight: h)
            stableR = road.imageCurve(side: 1, fPx: f, hCamM: hCam, yHorizonPx: yH, imageWidth: w, imageHeight: h)
        }
        var roiNorm = p.calibration.roi
        if let poly = LaneROI.polygon(left: stableL, right: stableR, calibrated: p.calibration.roi) {
            roiNorm = poly
        }
        pipeline.roi = Lane.roiToPixels(roiNorm, width: w, height: h)

        updateNight(pb)
        let t0 = CACurrentMediaTime()
        var dets: [Detection] = []
        var lightDets: [Detection] = []
        var classes = Set(p.config.detection.classes)
        if p.settings.trafficLights { classes.insert(Self.trafficLightClass) }
        if let detector {
            do {
                dets = try detector.detect(pb, frameWidth: w, frameHeight: h,
                                           classes: classes,
                                           minConf: night ? min(p.config.detection.minConf, Self.nightMinConf) : p.config.detection.minConf)
            } catch {
                detectorError = error.localizedDescription
            }
        }
        let t1 = CACurrentMediaTime()
        lightDets = dets.filter { $0.cls == Self.trafficLightClass }
        dets.removeAll { $0.cls == Self.trafficLightClass }
        if let last = lastFrameTime, t1 > last {
            let inst = 1.0 / (t1 - last)
            fpsEMA = fpsEMA == 0 ? inst : 0.9 * fpsEMA + 0.1 * inst
        }
        lastFrameTime = t1

        let gps = speed.current()
        let v = p.settings.simulatedSpeedKmh ?? gps?.kmh
        let r = pipeline.step(frame: frameIndex, t: t, speedKmh: v, detections: dets)
        frameIndex += 1

        // Xe ngược chiều: theo từng track, khoảng cách theo bề rộng + lệch ngang so với tâm làn mình.
        var obs: [OncomingClassifier.Observation] = []
        for (i, d) in dets.enumerated() {
            guard i < r.trackIds.count, let id = r.trackIds[i], let wReal = p.config.vehicleWidthM[d.cls], d.width > 0, f > 0
            else { continue }
            let z = f * wReal / d.width
            let x = ((d.x1 + d.x2) / 2 - w / 2) * z / f
            obs.append(.init(id: id, distance: z, lateral: x - road.center(z)))
        }
        let oncomingIds = oncoming.update(t: t, ownSpeedMps: v.map { $0 / 3.6 }, laneHalfWidth: road.width / 2, observations: obs)
        pipeline.excludedTracks = oncomingIds   // frame sau không chọn xe ngược chiều làm xe phía trước
        let nearestLane = obs.filter { oncomingIds.contains($0.id) }
            .map { max(1, Int(ceil((-$0.lateral - road.width / 2) / road.width))) }.min()
        if let n = nearestLane {
            oncomingLane = (n, t)
        } else if let o = oncomingLane, t - o.t > 3 {
            oncomingLane = nil
        }

        // Con đường đang chạy (OSM): tra mỗi giây; khớp được thì giữ 5 s phòng GPS chập chờn.
        if t - roadLookupT >= 1, let roads, let g = gps {
            roadLookupT = t
            if p.settings.autoRoads { roads.ensureAround(lat: g.lat, lon: g.lon) }
            if let m = roads.match(lat: g.lat, lon: g.lon, courseDeg: g.courseDeg) {
                roadMatch = (m, t)
            } else if let rm = roadMatch, t - rm.t > 5 {
                roadMatch = nil
            }
            // đứng yên thì GPS không có hướng: giữ đường phía trước cũ
            if let course = g.courseDeg {
                if let a = roads.ahead(lat: g.lat, lon: g.lon, courseDeg: course) {
                    roadAhead = (a, t, 0, t)
                } else if let ra = roadAhead, t - ra.t > 5 {
                    roadAhead = nil
                }
            }
        }
        // giữa hai lần tra: dịch đường phía trước theo quãng xe đã đi
        if var ra = roadAhead {
            ra.travelled += max(0, (v ?? 0) / 3.6) * max(0, t - ra.lastT)
            ra.lastT = t
            roadAhead = ra
        }

        // Sự kiện đường (docs/DRIVER_ASSIST.md A1): quãng đường, đứng yên, rẽ, ngã tư kế tiếp.
        let odo = odometer.update(t: t, speedKmh: v)
        let stoppedS = stopDetector.update(t: t, speedKmh: v)
        let turn = turnDetector.update(t: t, yawRateDegS: motion.currentYawRate(), courseDeg: gps?.courseDeg, speedKmh: v)
        let ahead = roadAhead.map { $0.ahead.advanced(by: $0.travelled) }
        let junction = junctions.update(odometer: odo, junctionsAhead: ahead?.junctions)
        if turn != nil { junctions.markPassed(odometer: odo) }

        // Đèn giao thông (A4): chọn đèn liên quan, màu theo HSV, bỏ phiếu; nhắc bằng giọng nói.
        var lightState: TrafficLightState?
        if p.settings.trafficLights {
            let picked = lightTracker.pick(lightDets, frameWidth: w, frameHeight: h)
            let color = picked.map { LightColorClassifier.classify(Self.samplePixels(pb, box: $0.box)) }
            lightState = lightTracker.update(t: t, light: picked, color: color)
            if p.settings.voiceOn, let m = lightRules.check(state: lightState, t: t, speedKmh: v,
                                                            junctionM: junction.nextM, stoppedS: stoppedS) {
                voice.offer(m)
            }
        } else {
            lightTracker.reset()
        }
        if p.settings.voiceOn { voice.tick(t: t) }

        if r.sound && p.settings.soundOn { sound.play() }
        let laneTag = (laneTracker.left != nil ? "L" : "") + (laneTracker.right != nil ? "R" : "")
        if p.settings.logOn {
            let extra = FrameLog.Extra(time: isoFormatter.string(from: Date()), fPx: f, fSource: source, nDets: dets.count,
                                       inferMs: (t1 - t0) * 1000, speedAccuracyKmh: gps?.accuracyKmh,
                                       thermal: thermal, lane: laneTag,
                                       pitchDeg: pitchDeg, yHorizon: pipeline.useGround ? yHorizon : nil)
            logger.append(FrameLog.row(r, extra))
        }

        var s = FrameSnapshot()
        s.result = r
        s.detections = dets
        s.kept = dets.map(pipeline.keeps)
        s.frameWidth = w
        s.frameHeight = h
        s.fPx = f
        s.fSource = source
        s.fIntrinsics = fx
        s.fHFOV = hfovF
        s.fps = fpsEMA
        s.inferMs = (t1 - t0) * 1000
        s.speedSimulated = p.settings.simulatedSpeedKmh != nil
        s.gpsOK = gps != nil
        s.detectorError = detectorError
        s.thermal = thermal
        s.targetFps = targetFps
        s.roiNorm = roiNorm
        s.laneLeft = stableL
        s.laneRight = stableR
        s.roadLane = road
        s.oncoming = r.trackIds.map { $0.map(oncomingIds.contains) ?? false }
        s.oncomingLane = oncomingLane?.index
        s.road = roadMatch?.match
        s.roadAhead = roadAhead.map { $0.ahead.advanced(by: $0.travelled) }
        s.yHorizon = yHorizon
        s.pitchDeg = pitchDeg
        s.light = lightState
        s.junctionM = junction.nextM
        s.lastTurn = turnDetector.lastTurn
        s.turning = turnDetector.turning
        s.stoppedS = stoppedS
        s.t = t
        onSnapshot?(s)
    }

    /// Kênh sáng (Y) của buffer 420 thu nhỏ về chiều rộng outWidth, để tìm vạch làn.
    /// Ban đêm (ảnh tối): hạ ngưỡng tin cậy của YOLO vì xe tối màu chỉ còn được ~0,2–0,3; tracker lọc box chập chờn.
    static let nightMinConf = 0.2
    private var lumaEMA: Double?
    private(set) var night = false

    /// Độ sáng trung bình (0..255) của kênh Y, lấy mẫu thưa.
    static func meanLuma(_ pb: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pb) >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard w > 0, h > 0 else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, n = 0
        for y in stride(from: h / 20, to: h, by: max(1, h / 20)) {
            for x in stride(from: w / 40, to: w, by: max(1, w / 40)) { sum += Int(src[y * bpr + x]); n += 1 }
        }
        return n > 0 ? Double(sum) / Double(n) : nil
    }

    private func updateNight(_ pb: CVPixelBuffer) {
        guard let l = Self.meanLuma(pb) else { return }
        let e = lumaEMA.map { 0.97 * $0 + 0.03 * l } ?? l
        lumaEMA = e
        if night { if e > 80 { night = false } } else if e < 60 { night = true }
    }

    /// Lấy mẫu RGB trên lưới nx × ny trong khung (pixel của frame) từ buffer 420 YCbCr full range.
    static func samplePixels(_ pb: CVPixelBuffer, box: Box, nx: Int = 10, ny: Int = 24) -> [(r: Double, g: Double, b: Double)] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pb) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return [] }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1)
        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        guard w > 0, h > 0, cw > 0, ch > 0 else { return [] }
        let ys = yBase.assumingMemoryBound(to: UInt8.self), cs = cBase.assumingMemoryBound(to: UInt8.self)
        var out: [(r: Double, g: Double, b: Double)] = []
        out.reserveCapacity(nx * ny)
        for j in 0..<ny {
            for i in 0..<nx {
                let x = Int(box.x1 + (Double(i) + 0.5) / Double(nx) * (box.x2 - box.x1))
                let y = Int(box.y1 + (Double(j) + 0.5) / Double(ny) * (box.y2 - box.y1))
                guard x >= 0, x < w, y >= 0, y < h else { continue }
                let cx = min(cw - 1, x * cw / w), cy = min(ch - 1, y * ch / h)
                let luma = Double(ys[y * yBpr + x])
                let cb = Double(cs[cy * cBpr + cx * 2]), cr = Double(cs[cy * cBpr + cx * 2 + 1])
                out.append(LightColorClassifier.rgb(y: luma, cb: cb, cr: cr))
            }
        }
        return out
    }

    static func gray(_ pb: CVPixelBuffer, outWidth: Int = 320) -> GrayImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pb) >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard w > 0, h > 0 else { return nil }
        let ow = min(outWidth, w), oh = max(1, h * ow / w)
        let src = base.assumingMemoryBound(to: UInt8.self)
        var px = [UInt8](repeating: 0, count: ow * oh)
        for y in 0..<oh {
            let row = src + (y * h / oh) * bpr
            for x in 0..<ow { px[y * ow + x] = row[x * w / ow] }
        }
        return GrayImage(width: ow, height: oh, pixels: px)
    }
}

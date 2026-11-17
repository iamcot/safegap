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
    /// Dò biển bằng model riêng (Models/signs*.mlpackage, docs/DRIVER_ASSIST.md B3). Không có model thì bỏ qua.
    var signDetection = true
    /// Lưu ảnh + nhãn gán sẵn để gán nhãn và train thêm (docs/DRIVER_ASSIST.md A6).
    var dataCapture = false

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
        signDetection = try c.decodeIfPresent(Bool.self, forKey: .signDetection) ?? d.signDetection
        dataCapture = try c.decodeIfPresent(Bool.self, forKey: .dataCapture) ?? d.dataCapture
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
    /// Biển cấm đang có hiệu lực (B5/B7).
    var activeSigns: [ActiveSign] = []
    /// Biển model dò biển đang thấy (đã đủ phiếu), toạ độ pixel frame.
    var seenSigns: [ConfirmedSign] = []
    /// Đã nạp model dò biển chưa (để hiện trạng thái trong Cài đặt).
    var signModel: String?
    /// Số biển trong bản đồ biển tự học.
    var rememberedSigns = 0
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
    /// Model dò biển (tuỳ chọn). Chạy ở hàng đợi riêng, mỗi lần một frame, kết quả dùng ở frame sau.
    private var signDetector: YOLODetector?
    private let signQueue = DispatchQueue(label: "safegap.signs", qos: .userInitiated)
    private var signBusy = false
    private var signResult: (t: Double, dets: [Detection], codes: [String?])?
    /// Lượt dò biển gần nhất: lúc nào, thấy mấy biển (thu dữ liệu chụp dày hơn khi có biển).
    private var lastSignSeen: (t: Double, n: Int)?
    private var signTracker = SignDetectionTracker()
    /// Bản đồ biển tự học trên tuyến hay đi (Documents/sign_map.json): nhắc biển đã nhớ trước cả khi camera thấy.
    private var signRecall = SignRecall(memory: FrameProcessor.loadSignMap())
    private var signMapDirty = false
    private var signMapSavedT = -1e9
    private var clearSignMapRequested = false
    private let saveQueue = DispatchQueue(label: "safegap.signmap", qos: .utility)

    static var signMapURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sign_map.json")
    }

    static func loadSignMap() -> SignMemory {
        guard let d = try? Data(contentsOf: signMapURL), let m = try? JSONDecoder().decode(SignMemory.self, from: d) else {
            return SignMemory()
        }
        return m
    }

    /// Gọi từ Cài đặt (luồng nào cũng được): xoá bản đồ biển ở frame sau.
    func clearSignMap() {
        lock.lock()
        clearSignMapRequested = true
        lock.unlock()
    }

    private func saveSignMapIfNeeded(t: Double, force: Bool = false) {
        guard signMapDirty, force || t - signMapSavedT > 30 else { return }
        signMapDirty = false
        signMapSavedT = t
        guard let data = try? JSONEncoder().encode(signRecall.memory) else { return }
        saveQueue.async { try? data.write(to: FrameProcessor.signMapURL, options: .atomic) }
    }
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
    let capture = DataCapture()
    private var signs: SignEngine
    /// Biển vừa thấy chờ xử lý ở frame sau (từ model nhận biển, hoặc nút giả lập trong Cài đặt).
    private var pendingSightings: [SignSighting] = []

    /// Gọi từ bất kỳ luồng nào: coi như xe vừa đi qua biển này.
    func addSighting(_ s: SignSighting) {
        lock.lock()
        pendingSightings.append(s)
        lock.unlock()
    }

    private func takeSightings() -> [SignSighting] {
        lock.lock()
        defer { lock.unlock() }
        let out = pendingSightings
        pendingSightings.removeAll()
        return out
    }
    static let trafficLightClass = "traffic light"
    private var thermalLevel: ThermalLevel = .nominal
    private var laneTracker = LaneTracker()
    /// Số frame liền không thấy vạch trong cửa sổ dự đoán; quá 30 thì dò lại cả ảnh.
    private var gateMisses = 0
    /// Khung xe frame trước (chuẩn hoá): không tìm vạch làn trên thân xe.
    private var lastVehicleBoxes: [NormBox] = []
    /// Lần dừng hiện tại là do kẹt xe (giữ tới khi xe chạy lại).
    private var stopJam = false
    /// Khoảng cách tới mép phải đường theo GPS + OSM lúc còn chạy, và sai số GPS (m).
    private var curbGap: (gap: Double, acc: Double)?
    /// Ghi log làn (vì sao vẽ sai): vạch thô frame này, có dùng cổng không, lý do bỏ.
    private var laneDebug = ""
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
         voice: VoiceAlerts, signConfig: SignConfig) {
        self.params = params
        self.signs = SignEngine(config: signConfig)
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
        signDetector = try? YOLODetector(prefix: "signs")
    }

    /// Gửi frame cho model biển nếu tới lượt và đang rảnh (không chặn hàng đợi camera).
    private func runSigns(_ pb: CVPixelBuffer, t: Double, w: Double, h: Double, night: Bool) {
        guard let sd = signDetector else { return }
        lock.lock()
        let busy = signBusy
        if !busy { signBusy = true }
        lock.unlock()
        guard !busy else { return }
        signQueue.async { [weak self] in
            // ngưỡng thấp: bộ đếm phiếu tự lọc 0,35; biển 0,2–0,35 vẫn dùng để thu thêm ảnh (model đang lưỡng lự)
            let dets = (try? sd.detect(pb, frameWidth: w, frameHeight: h, classes: nil, minConf: 0.2)) ?? []
            // model cũ gộp cấm dừng đỗ với cấm đỗ: đếm vạch đỏ chéo trong biển để tách P.130 / P.131a
            let codes: [String?] = dets.map { d in
                guard d.cls == SignGroup.noStopPark.rawValue, d.box.y2 - d.box.y1 >= 16 else { return nil }
                return NoStopParkClassifier.classify(Self.samplePixels(pb, box: d.box, nx: 16, ny: 16))
            }
            guard let self else { return }
            self.lock.lock()
            self.signResult = (t, dets, codes)
            self.signBusy = false
            self.lock.unlock()
        }
    }

    private func takeSignResult() -> (t: Double, dets: [Detection], codes: [String?])? {
        lock.lock()
        defer { lock.unlock() }
        let r = signResult
        signResult = nil
        return r
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
        let laneFrozen = isStopped
        var rawL: LaneCurve?, rawR: LaneCurve?, gated = false, masked = 0, offHorizon = ""
        if p.settings.laneFollow, !laneFrozen, let gray = Self.gray(pb) {
            let cal = p.calibration
            let top = cal.roi.map(\.y).min() ?? 0.45
            var lc = LaneConfig()
            lc.yBottom = min(0.95, cal.maxBottomRatio - 0.02)
            lc.yTop = top + 0.25 * (lc.yBottom - top)
            if f > 0 { lc.yTop = max(lc.yTop, min(lc.yBottom - 0.12, (yH + f * hCam / 25) / h)) }
            let (tl, tr) = (laneTracker.left, laneTracker.right)
            let prev = roadLane.lane
            var gate: ((Double) -> (left: Double, right: Double, tol: Double))?
            if prev.tracked, gateMisses < 30, !roadLane.needsReacquire, f > 0 {
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
            }, gate: gate, exclude: lastVehicleBoxes,
               horizon: f > 0 ? HorizonCheck(yHorizonNorm: yH / h, fPx: f, imageWidth: w) : nil)
            rawL = d.left; rawR = d.right; gated = gate != nil; masked = d.masked; offHorizon = d.offHorizon
            let found = d.left != nil || d.right != nil
            if found { gateMisses = 0 } else if gate != nil { gateMisses += 1 }
            laneTracker.update(d)
        } else if laneFrozen {
            // đứng yên: không dò (xe khác che vạch, vạch sai không tự hết); dò lại từ đầu khi xe chạy
            laneTracker.reset()
            gateMisses = 30
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
        let road = laneFrozen ? roadLane.stationary()
                              : roadLane.update(left: ground(laneTracker.left), right: ground(laneTracker.right))
        func c3(_ c: LaneCurve?) -> String { c.map { String(format: "%.3f/%.2f", $0.c0, $0.c1) } ?? "-" }
        laneDebug = laneFrozen ? "frozen" : String(format: "raw %@ %@ g%d m%d rej %@ | off %.2f hd %.3f w %.2f %@ hz %@",
                                                   c3(rawL), c3(rawR), gated ? 1 : 0, masked, roadLane.lastReject,
                                                   road.offset, road.heading, road.width, road.tracked ? "T" : "-",
                                                   offHorizon.isEmpty ? "-" : offHorizon)
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
        if p.settings.signDetection, signDetector != nil,
           scheduler.shouldRun(.signsLights, t: t, thermal: thermal, isStopped: isStopped) {
            runSigns(pb, t: t, w: w, h: h, night: night)
        }
        lightDets = dets.filter { $0.cls == Self.trafficLightClass }
        dets.removeAll { $0.cls == Self.trafficLightClass }
        lastVehicleBoxes = dets.map { NormBox($0.x1 / w, $0.y1 / h, $0.x2 / w, $0.y2 / h) }
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
        var lightDebug = ""
        if p.settings.trafficLights {
            let picked = lightTracker.pick(lightDets, frameWidth: w, frameHeight: h)
            // qua ngã tư / vừa rẽ: đèn cũ không còn áp dụng
            if junction.passed || turn != nil { lightTracker.reset() }
            let color = picked.map { d in
                LightColorClassifier.classify(Self.samplePixels(pb, box: d.box),
                                              aspect: (d.y2 - d.y1) / max(1, d.x2 - d.x1))
            }
            lightState = lightTracker.update(t: t, light: picked, color: color, speedKmh: v)
            lightDebug = String(format: "%d lights raw %@ state %@ h %.0f", lightDets.count, color?.rawValue ?? "-",
                                lightState?.color.rawValue ?? "-", picked.map { $0.y2 - $0.y1 } ?? 0)
            if p.settings.voiceOn, let m = lightRules.check(state: lightState, t: t, speedKmh: v,
                                                            junctionM: junction.nextM, stoppedS: stoppedS) {
                voice.offer(m)
            }
        } else {
            lightTracker.reset()
        }
        // Biển báo (B5/B6): luật hiệu lực theo QCVN 41 (config/signs_vn.json), cảnh báo sắp vi phạm.
        let cal = Calendar.current.dateComponents([.hour, .minute, .day], from: Date())
        let minuteOfDay = (cal.hour ?? 12) * 60 + (cal.minute ?? 0), day = cal.day ?? 1
        var signMsgs: [VoiceMessage] = []
        // vị trí đủ tin để định vị biển: có hướng đi, sai số GPS ≤ 25 m
        let fix: (lat: Double, lon: Double, course: Double)? = gps.flatMap { g in
            guard let c = g.courseDeg, g.horizontalAccuracyM > 0, g.horizontalAccuracyM <= 25 else { return nil }
            return (g.lat, g.lon, c)
        }
        lock.lock()
        let clearMap = clearSignMapRequested
        clearSignMapRequested = false
        lock.unlock()
        if clearMap {
            signRecall.clear()
            signMapDirty = true
            saveSignMapIfNeeded(t: t, force: true)
        }
        if let sr = takeSignResult() {
            lastSignSeen = (sr.t, sr.dets.count)
            // biển từ model: đủ phiếu qua nhiều lượt mới tính là đã đi qua biển
            // biển chỉ có hiệu lực cho phần đường bên trái nó: biển xa bên phải là của đường ngang / nhánh
            let lanes = Double(roadMatch?.match?.lanesSame ?? 2)
            signTracker.maxLateralM = max(8, lanes * 3.5 + 3.5)
            signTracker.leftSideApplies = roadMatch?.match?.oneway == true
            // đường cong (OSM): trừ độ cong để biết biển nằm lề phải hay giữa đường thật
            let bend: ((Double) -> Double?)? = ahead.map { a in { z in a.x(at: z).map { $0 - (a.x(at: 0) ?? 0) } } }
            for c in signTracker.update(t: sr.t, signs: sr.dets, vehicles: dets, frameWidth: w, frameHeight: h, fPx: f,
                                        roadBend: bend, codes: sr.codes) {
                if let fx = fix, signs.isOwnRoadSign(c), let code = c.lawCode {
                    signRecall.cameraSaw(code: code, group: c.group.rawValue, carLat: fx.lat, carLon: fx.lon,
                                         courseDeg: fx.course, aheadM: c.distanceM ?? 0, lateralM: c.lateralM ?? 0,
                                         odometer: odo, time: Date().timeIntervalSince1970)
                    signMapDirty = true
                }
                signMsgs += signs.feed(c, odometer: odo, t: t, minuteOfDay: minuteOfDay, dayOfMonth: day)
            }
        } else if !p.settings.signDetection {
            signTracker.reset()
        }
        for sg in takeSightings() {
            signMsgs += signs.sighted(sg, odometer: odo, t: t, minuteOfDay: minuteOfDay, dayOfMonth: day)
        }
        // biển đã nhớ trên tuyến: sắp tới thì đưa vào luật (hiệu lực từ chỗ cắm), kể cả khi camera chưa / không thấy
        if let fx = fix {
            let rc = signRecall.update(lat: fx.lat, lon: fx.lon, courseDeg: fx.course, odometer: odo,
                                       cameraActive: p.settings.signDetection && signDetector != nil)
            if rc.changed { signMapDirty = true }
            for u in rc.due {
                signMsgs += signs.sightedAhead(SignSighting(code: u.sign.code), aheadM: u.aheadM, odometer: odo, t: t,
                                               minuteOfDay: minuteOfDay, dayOfMonth: day)
            }
        }
        saveSignMapIfNeeded(t: t)
        // Cấm dừng / đỗ chỉ tính khi xe có thể đang sát lề phải. Không tính khi: có xe ngay bên phải (làn bên phải,
        // lệch 1,5–5 m, gần < 10 m), hoặc GPS + số làn OSM cho thấy xe cách mép phải hơn 1,5 làn kể cả sai số GPS.
        // Xe sát phía trước KHÔNG được miễn (đỗ sau một xe đang đỗ cũng vậy). Thấy một lần là miễn cả lần dừng.
        let vehicleRight = f > 0 && dets.contains { d in
            let dy = d.y2 - yH
            guard dy > 1 else { return false }
            let z = f * hCam / dy, x = ((d.x1 + d.x2) / 2 - w / 2) * z / f
            return z < 10 && x > 1.5 && x < 5
        }
        if stoppedS == nil, let m = roadMatch?.match, let gap = m.rightEdgeGapM, let g = gps, g.courseDeg != nil,
           g.horizontalAccuracyM > 0 {
            curbGap = (gap, g.horizontalAccuracyM)   // lúc còn chạy (có hướng đi); đứng yên thì giữ số này
        } else if stoppedS == nil, roadMatch == nil {
            curbGap = nil
        }
        let farFromCurb = curbGap.map { $0.gap - $0.acc > RoadMatch.laneWidthM * 1.5 } ?? false
        stopJam = stoppedS != nil && (stopJam || vehicleRight || farFromCurb)
        let jam = stopJam
        signMsgs += signs.update(DriveContext(t: t, odometer: odo, minuteOfDay: minuteOfDay, dayOfMonth: day, speedKmh: v,
                                              stoppedS: stoppedS, stopExcused: jam || lightState?.color == .red,
                                              junctionM: junction.nextM, junctionPassed: junction.passed,
                                              turn: turn, turning: turnDetector.turning,
                                              mapSpeedLimitKmh: roadMatch?.match?.maxspeed))
        if p.settings.voiceOn { signMsgs.forEach(voice.offer) }

        if p.settings.voiceOn { voice.tick(t: t) }

        // Thu dữ liệu (A6): ảnh + nhãn gán sẵn từ model hiện tại (xe + đèn).
        if p.settings.dataCapture {
            capture.start()
            capture.offer(pb, t: t, frameWidth: w, frameHeight: h, detections: dets + lightDets, speed: gps, speedKmh: v,
                          light: lightState?.box != nil ? lightState?.color : nil, thermal: thermal,
                          signCount: lastSignSeen.flatMap { t - $0.t < 0.8 ? $0.n : nil } ?? 0,
                          laneDebug: laneDebug, lightDebug: lightDebug)
        } else if capture.isRunning {
            capture.stop()
        }

        if r.sound && p.settings.soundOn { sound.play() }
        let laneTag = (laneTracker.left != nil ? "L" : "") + (laneTracker.right != nil ? "R" : "")
        if p.settings.logOn {
            var extra = FrameLog.Extra(time: isoFormatter.string(from: Date()), fPx: f, fSource: source, nDets: dets.count,
                                       inferMs: (t1 - t0) * 1000, speedAccuracyKmh: gps?.accuracyKmh,
                                       thermal: thermal, lane: laneTag,
                                       pitchDeg: pitchDeg, yHorizon: pipeline.useGround ? yHorizon : nil)
            extra.laneDebug = laneDebug
            extra.lightDebug = lightDebug
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
        s.activeSigns = signs.active
        s.seenSigns = t - (signTracker.visible.map(\.t).max() ?? -10) < 1.5 ? signTracker.visible : []
        s.signModel = signDetector?.modelName
        s.rememberedSigns = signRecall.memory.signs.count
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
    static func samplePixels(_ pb: CVPixelBuffer, box: Box, nx: Int = 10, ny: Int = 24)
        -> [(r: Double, g: Double, b: Double, u: Double, v: Double)] {
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
        // khung ngang (đèn treo ngang): lưới đổi chiều cho đều
        let horizontal = box.x2 - box.x1 > box.y2 - box.y1
        let (gx, gy) = horizontal ? (ny, nx) : (nx, ny)
        var out: [(r: Double, g: Double, b: Double, u: Double, v: Double)] = []
        out.reserveCapacity(gx * gy)
        for j in 0..<gy {
            for i in 0..<gx {
                let u = (Double(i) + 0.5) / Double(gx), v = (Double(j) + 0.5) / Double(gy)
                let x = Int(box.x1 + u * (box.x2 - box.x1))
                let y = Int(box.y1 + v * (box.y2 - box.y1))
                guard x >= 0, x < w, y >= 0, y < h else { continue }
                let cx = min(cw - 1, x * cw / w), cy = min(ch - 1, y * ch / h)
                let luma = Double(ys[y * yBpr + x])
                let cb = Double(cs[cy * cBpr + cx * 2]), cr = Double(cs[cy * cBpr + cx * 2 + 1])
                let c = LightColorClassifier.rgb(y: luma, cb: cb, cr: cr)
                out.append((r: c.r, g: c.g, b: c.b, u: u, v: v))
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

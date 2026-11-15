// Xử lý từng frame trên hàng đợi camera: f theo máy → YOLO → Pipeline (port từ Python) → âm thanh, log, HUD.
import CoreMedia
import Foundation
import QuartzCore
import SafeGapCore

/// Cài đặt người dùng (lưu UserDefaults).
struct UserSettings: Codable, Equatable {
    var soundOn = true
    var logOn = true
    /// d_min chỉnh tay (biển cự ly, trời mưa). nil = theo bảng luật.
    var manualDMinM: Double?
    /// Chỉ để thử khi đứng yên. nil = dùng GPS.
    var simulatedSpeedKmh: Double?
    /// Ngưỡng tốc độ bắt đầu cảnh báo. nil = theo config (40 km/h). Hạ xuống để thử trong phố.
    var minSpeedKmh: Double?

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
    let logger: CSVLogger
    let sound: AlertSound
    var hfovDeg: Double?
    let thermalPolicy = ThermalPolicy()
    private var throttle = FrameThrottle()
    private var thermalLevel: ThermalLevel = .nominal

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

    init(params: Params, speed: SpeedProvider, logger: CSVLogger, sound: AlertSound) {
        self.params = params
        self.speed = speed
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
        let targetFps = thermalPolicy.targetFps(thermal)
        // Máy nóng: bỏ bớt frame (YOLO là phần tốn pin / nhiệt nhất). Kalman dùng dt thật nên vẫn đúng.
        guard throttle.shouldProcess(t: t, targetFps: targetFps) else { return }

        let fx = CameraController.intrinsicsFx(sb)
        let hfovF = hfovDeg.flatMap { FocalLength.fromHFOV(imageWidthPx: w, hfovDeg: $0) }
        let (f, source) = p.calibration.resolveF(frameWidth: w, intrinsicsFx: fx, hfovF: hfovF, config: p.config)

        if pipeline == nil || pipelineVersion != p.version || pipelineW != w || pipelineH != h {
            var cfg = p.calibration.apply(to: p.config, fPx: f, frameWidth: w)
            cfg.alert.manualDMinM = p.settings.manualDMinM
            if let m = p.settings.minSpeedKmh { cfg.alert.minSpeedKmh = m }
            pipeline = Pipeline(config: cfg, law: p.law, frameWidth: w, frameHeight: h)
            pipelineVersion = p.version
            pipelineW = w
            pipelineH = h
        }
        guard let pipeline else { return }
        pipeline.fPx = f

        let t0 = CACurrentMediaTime()
        var dets: [Detection] = []
        if let detector {
            do {
                dets = try detector.detect(pb, frameWidth: w, frameHeight: h,
                                           classes: Set(p.config.detection.classes), minConf: p.config.detection.minConf)
            } catch {
                detectorError = error.localizedDescription
            }
        }
        let t1 = CACurrentMediaTime()
        if let last = lastFrameTime, t1 > last {
            let inst = 1.0 / (t1 - last)
            fpsEMA = fpsEMA == 0 ? inst : 0.9 * fpsEMA + 0.1 * inst
        }
        lastFrameTime = t1

        let gps = speed.current()
        let v = p.settings.simulatedSpeedKmh ?? gps?.kmh
        let r = pipeline.step(frame: frameIndex, t: t, speedKmh: v, detections: dets)
        frameIndex += 1

        if r.sound && p.settings.soundOn { sound.play() }
        if p.settings.logOn {
            let extra = FrameLog.Extra(time: isoFormatter.string(from: Date()), fPx: f, fSource: source, nDets: dets.count,
                                       inferMs: (t1 - t0) * 1000, speedAccuracyKmh: gps?.accuracyKmh,
                                       thermal: thermal)
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
        onSnapshot?(s)
    }
}

// Trạng thái app: nạp config, nối camera → FrameProcessor → giao diện.
import AVFoundation
import Foundation
import SafeGapCore
import SwiftUI
import UIKit

final class AppModel: ObservableObject {
    enum Screen { case hud, calibration }

    @Published var screen: Screen = .hud
    @Published private(set) var snapshot = FrameSnapshot()
    @Published private(set) var calibration: DeviceCalibration
    @Published var editor: CalibrationEditor?
    @Published var errorMessage: String?
    @Published private(set) var logURL: URL?
    @Published var settings: UserSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            applyLogging()
            pushParams()
        }
    }

    let config: AppConfig
    let law: LawConfig
    let camera = CameraController()
    let speed = SpeedProvider()
    let sound = AlertSound()
    let logger = CSVLogger()
    private var processor: FrameProcessor!
    private var version = 0
    private var started = false

    init() {
        var loadError: String?
        func loadJSON<T>(_ name: String, _ decode: (Data) throws -> T) -> T? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
                loadError = "Thiếu \(name).json trong app"
                return nil
            }
            do { return try decode(Data(contentsOf: url)) } catch {
                loadError = "Lỗi đọc \(name).json: \(error)"
                return nil
            }
        }
        let cfg = loadJSON("default", AppConfig.decode) ?? AppModel.fallbackConfig
        let law = loadJSON("law_vn", LawConfig.decode) ?? AppModel.fallbackLaw
        config = cfg
        self.law = law
        settings = UserSettings.load()

        let defaults = DeviceCalibration.defaults(from: cfg, deviceModel: CalibrationStore.deviceModel, lens: CameraController.lens,
                                                  frameWidth: CameraController.frameWidth, frameHeight: CameraController.frameHeight)
        calibration = CalibrationStore.load(key: defaults.storageKey) ?? defaults
        errorMessage = loadError

        processor = FrameProcessor(params: currentParams(), speed: speed, logger: logger, sound: sound)
        processor.onSnapshot = { [weak self] s in
            DispatchQueue.main.async { self?.snapshot = s }
        }
        camera.onFrame = { [weak self] sb in self?.processor.process(sb) }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.applyThermal() }
    }

    static func thermalLevel(_ s: ProcessInfo.ThermalState) -> ThermalLevel {
        switch s {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    /// Máy nóng thì giảm fps camera + số frame chạy YOLO.
    private func applyThermal() {
        let level = Self.thermalLevel(ProcessInfo.processInfo.thermalState)
        processor.setThermal(level)
        camera.setFrameRate(processor.thermalPolicy.targetFps(level))
    }

    /// Giá trị dự phòng nếu file config hỏng; bình thường luôn đọc từ config/*.json trong app.
    static let fallbackConfig = AppConfig(
        camera: CameraConfig(fPx: 1530, fPxImageWidth: 2100),
        vehicleWidthM: ["car": 1.8, "truck": 2.5, "bus": 2.5],
        roi: RoiConfig(polygon: [Point(0.42, 0.45), Point(0.58, 0.45), Point(0.80, 1.0), Point(0.20, 1.0)]))
    static let fallbackLaw = LawConfig(table: [.init(maxKmh: 60, dMinM: 35), .init(maxKmh: 80, dMinM: 55),
                                              .init(maxKmh: 100, dMinM: 70), .init(maxKmh: 120, dMinM: 100)])

    var isCalibrated: Bool { calibration.updatedAt != nil }

    private func currentParams() -> FrameProcessor.Params {
        FrameProcessor.Params(config: config, law: law, calibration: calibration, settings: settings, version: version)
    }

    private func pushParams() {
        version += 1
        processor.setParams(currentParams())
    }

    func start() {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true
        sound.prepare()
        speed.start()
        applyLogging()
        Task {
            guard await CameraController.requestAccess() else {
                await MainActor.run { self.errorMessage = CameraError.notAuthorized.localizedDescription }
                return
            }
            self.camera.start { [weak self] err in
                guard let self else { return }
                if let err { self.errorMessage = err.localizedDescription }
                self.processor.hfovDeg = self.camera.hfovDeg
                self.applyThermal()
            }
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            UIApplication.shared.isIdleTimerDisabled = true
            if started { camera.start { _ in } }
        case .background:
            logger.flush()
            camera.stop()
        default:
            logger.flush()
        }
    }

    private func applyLogging() {
        if settings.logOn {
            if !logger.isRunning { logURL = try? logger.start() }
        } else if logger.isRunning {
            logger.stop()
            logURL = nil
        }
    }

    // MARK: hiệu chỉnh

    func beginCalibration() {
        editor = CalibrationEditor(calibration: calibration)
        screen = .calibration
    }

    func saveCalibration() {
        guard let e = editor else { return }
        CalibrationStore.save(e.draft)
        calibration = CalibrationStore.load(key: e.draft.storageKey) ?? e.draft
        pushParams()
        endCalibration()
    }

    func resetCalibrationToDefaults() {
        let d = DeviceCalibration.defaults(from: config, deviceModel: calibration.deviceModel, lens: calibration.lens,
                                           frameWidth: calibration.frameWidth, frameHeight: calibration.frameHeight)
        editor?.draft = d
    }

    func endCalibration() {
        editor = nil
        screen = .hud
    }
}

/// Bản nháp khi đang ở màn hiệu chỉnh. Chỉ áp dụng khi bấm Lưu.
final class CalibrationEditor: ObservableObject {
    @Published var draft: DeviceCalibration
    // Đo tờ A4: 2 vạch dọc (pixel của frame) ở 2 mép tờ giấy dán ngang trên tường.
    @Published var a4On = false
    @Published var a4Left: Double
    @Published var a4Right: Double
    @Published var a4DistanceM = 2.0
    @Published var a4WidthM = FocalLength.a4LongSideM

    init(calibration: DeviceCalibration) {
        draft = calibration
        a4Left = calibration.frameWidth / 2 - 100
        a4Right = calibration.frameWidth / 2 + 100
    }

    var a4F: Double? {
        FocalLength.fromReference(wPx: abs(a4Right - a4Left), distanceM: a4DistanceM, realWidthM: a4WidthM)
    }
}

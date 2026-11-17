// Đọc config/default.json và config/law_vn.json (cùng file với bản Python).
// Giá trị mặc định khi thiếu khoá giống các .get(..., default) trong proto/.
import Foundation

public struct CameraConfig: Codable, Equatable, Sendable {
    /// Trong app iOS, f lấy theo từng máy (intrinsics / hiệu chỉnh), app ghi đè 2 giá trị này trước khi tạo Pipeline.
    public var fPx: Double
    public var fPxImageWidth: Double
    public var hCamM: Double

    public init(fPx: Double, fPxImageWidth: Double, hCamM: Double = 1.2) {
        self.fPx = fPx; self.fPxImageWidth = fPxImageWidth; self.hCamM = hCamM
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fPx = try c.decode(Double.self, forKey: .fPx)
        fPxImageWidth = try c.decode(Double.self, forKey: .fPxImageWidth)
        hCamM = try c.decodeIfPresent(Double.self, forKey: .hCamM) ?? 1.2
    }
}

public struct DetectionConfig: Codable, Equatable, Sendable {
    public var classes: [String]
    public var minConf: Double
    public var maxWidthRatio: Double
    public var maxBottomRatio: Double

    public init(classes: [String] = ["car", "truck", "bus"], minConf: Double = 0.35,
                maxWidthRatio: Double = 0.7, maxBottomRatio: Double = 0.97) {
        self.classes = classes; self.minConf = minConf
        self.maxWidthRatio = maxWidthRatio; self.maxBottomRatio = maxBottomRatio
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        classes = try c.decodeIfPresent([String].self, forKey: .classes) ?? ["car", "truck", "bus"]
        minConf = try c.decodeIfPresent(Double.self, forKey: .minConf) ?? 0.35
        maxWidthRatio = try c.decodeIfPresent(Double.self, forKey: .maxWidthRatio) ?? 0.7
        maxBottomRatio = try c.decodeIfPresent(Double.self, forKey: .maxBottomRatio) ?? 0.97
    }
}

public struct RoiConfig: Codable, Equatable, Sendable {
    /// Hình thang chọn xe cùng làn, toạ độ chuẩn hoá 0..1, y tính từ trên xuống.
    public var polygon: [Point]
    public init(polygon: [Point]) { self.polygon = polygon }
}

public struct DistanceConfig: Codable, Equatable, Sendable {
    public var useGround: Bool
    public var yHorizonNorm: Double
    public var fuseFarM: Double

    public init(useGround: Bool = false, yHorizonNorm: Double = 0.45, fuseFarM: Double = 40.0) {
        self.useGround = useGround; self.yHorizonNorm = yHorizonNorm; self.fuseFarM = fuseFarM
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        useGround = try c.decodeIfPresent(Bool.self, forKey: .useGround) ?? false
        yHorizonNorm = try c.decodeIfPresent(Double.self, forKey: .yHorizonNorm) ?? 0.45
        fuseFarM = try c.decodeIfPresent(Double.self, forKey: .fuseFarM) ?? 40.0
    }
}

public struct TrackerConfig: Codable, Equatable, Sendable {
    public var iouMatch: Double
    public var maxMissed: Int
    public var accelSigma: Double
    public var measRelSigma: Double

    public init(iouMatch: Double = 0.3, maxMissed: Int = 10, accelSigma: Double = 3.0, measRelSigma: Double = 0.08) {
        self.iouMatch = iouMatch; self.maxMissed = maxMissed
        self.accelSigma = accelSigma; self.measRelSigma = measRelSigma
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iouMatch = try c.decodeIfPresent(Double.self, forKey: .iouMatch) ?? 0.3
        maxMissed = try c.decodeIfPresent(Int.self, forKey: .maxMissed) ?? 10
        accelSigma = try c.decodeIfPresent(Double.self, forKey: .accelSigma) ?? 3.0
        measRelSigma = try c.decodeIfPresent(Double.self, forKey: .measRelSigma) ?? 0.08
    }
}

public struct AlertConfig: Codable, Equatable, Sendable {
    public var redRatio: Double
    public var yellowRatio: Double
    public var holdS: Double
    public var minSpeedKmh: Double
    public var soundCooldownS: Double
    /// d_min chỉnh tay (biển "Cự ly tối thiểu", trời mưa). nil hoặc 0 = theo bảng luật.
    public var manualDMinM: Double?

    public init(redRatio: Double = 0.9, yellowRatio: Double = 1.1, holdS: Double = 1.0, minSpeedKmh: Double = 40.0,
                soundCooldownS: Double = 5.0, manualDMinM: Double? = nil) {
        self.redRatio = redRatio; self.yellowRatio = yellowRatio; self.holdS = holdS
        self.minSpeedKmh = minSpeedKmh; self.soundCooldownS = soundCooldownS; self.manualDMinM = manualDMinM
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        redRatio = try c.decodeIfPresent(Double.self, forKey: .redRatio) ?? 0.9
        yellowRatio = try c.decodeIfPresent(Double.self, forKey: .yellowRatio) ?? 1.1
        holdS = try c.decodeIfPresent(Double.self, forKey: .holdS) ?? 1.0
        minSpeedKmh = try c.decodeIfPresent(Double.self, forKey: .minSpeedKmh) ?? 40.0
        soundCooldownS = try c.decodeIfPresent(Double.self, forKey: .soundCooldownS) ?? 5.0
        manualDMinM = try c.decodeIfPresent(Double.self, forKey: .manualDMinM)
    }
}

/// config/default.json
public struct AppConfig: Codable, Equatable, Sendable {
    public var camera: CameraConfig
    public var vehicleWidthM: [String: Double]
    public var detection: DetectionConfig
    public var roi: RoiConfig
    public var distance: DistanceConfig
    public var tracker: TrackerConfig
    public var alert: AlertConfig

    public init(camera: CameraConfig, vehicleWidthM: [String: Double], detection: DetectionConfig = .init(),
                roi: RoiConfig, distance: DistanceConfig = .init(), tracker: TrackerConfig = .init(),
                alert: AlertConfig = .init()) {
        self.camera = camera; self.vehicleWidthM = vehicleWidthM; self.detection = detection
        self.roi = roi; self.distance = distance; self.tracker = tracker; self.alert = alert
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        camera = try c.decode(CameraConfig.self, forKey: .camera)
        vehicleWidthM = try c.decode([String: Double].self, forKey: .vehicleWidthM)
        detection = try c.decodeIfPresent(DetectionConfig.self, forKey: .detection) ?? .init()
        roi = try c.decode(RoiConfig.self, forKey: .roi)
        distance = try c.decodeIfPresent(DistanceConfig.self, forKey: .distance) ?? .init()
        tracker = try c.decodeIfPresent(TrackerConfig.self, forKey: .tracker) ?? .init()
        alert = try c.decodeIfPresent(AlertConfig.self, forKey: .alert) ?? .init()
    }

    public static func decode(_ data: Data) throws -> AppConfig {
        try ConfigJSON.decoder().decode(AppConfig.self, from: data)
    }
}

/// config/law_vn.json
public struct LawConfig: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public var maxKmh: Double
        public var dMinM: Double
        public init(maxKmh: Double, dMinM: Double) { self.maxKmh = maxKmh; self.dMinM = dMinM }
    }

    public var source: String?
    public var table: [Row]
    /// Dưới mốc đầu của bảng (60 km/h) luật không cho số, chỉ yêu cầu "giữ khoảng cách phù hợp": dùng quy tắc
    /// N giây (quãng đường đi trong N s), không vượt d_min của mốc đầu. nil = dùng luôn d_min mốc đầu.
    public var belowFirstHeadwayS: Double?

    public init(source: String? = nil, table: [Row], belowFirstHeadwayS: Double? = nil) {
        self.source = source; self.table = table; self.belowFirstHeadwayS = belowFirstHeadwayS
    }

    public static func decode(_ data: Data) throws -> LawConfig {
        try ConfigJSON.decoder().decode(LawConfig.self, from: data)
    }
}

public enum ConfigJSON {
    /// Khoá trong JSON viết snake_case (f_px, max_width_ratio...).
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

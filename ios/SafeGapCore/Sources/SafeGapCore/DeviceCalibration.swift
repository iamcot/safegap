// Hiệu chỉnh theo từng máy: lưu trên điện thoại, không dùng giá trị cố định trong config/default.json.
import Foundation

/// f lấy từ đâu (ưu tiên từ trên xuống).
public enum FocalSource: String, Codable, Sendable {
    case manual      // người dùng đo tờ A4 trong màn hiệu chỉnh và bấm lưu
    case intrinsics  // AVFoundation cameraIntrinsicMatrix (fx) của frame
    case hfov        // tính từ góc nhìn ngang của định dạng camera
    case config      // giá trị trong default.json (chỉ khi không có gì khác)
}

public struct DeviceCalibration: Codable, Equatable, Sendable {
    /// Ví dụ "iPhone15,2"; lens và độ phân giải cố định trong app nên khoá theo máy + lens + độ phân giải.
    public var deviceModel: String
    public var lens: String
    public var frameWidth: Double
    public var frameHeight: Double
    /// f đo tay (A4), cùng hệ pixel với frameWidth. nil = dùng intrinsics.
    public var manualFPx: Double?
    /// ROI chuẩn hoá 0..1 theo vị trí gắn máy.
    public var roi: [Point]
    public var maxWidthRatio: Double
    public var maxBottomRatio: Double
    public var hCamM: Double
    public var updatedAt: Date?

    public init(deviceModel: String, lens: String, frameWidth: Double, frameHeight: Double, manualFPx: Double? = nil,
                roi: [Point], maxWidthRatio: Double, maxBottomRatio: Double, hCamM: Double, updatedAt: Date? = nil) {
        self.deviceModel = deviceModel; self.lens = lens
        self.frameWidth = frameWidth; self.frameHeight = frameHeight
        self.manualFPx = manualFPx; self.roi = roi
        self.maxWidthRatio = maxWidthRatio; self.maxBottomRatio = maxBottomRatio
        self.hCamM = hCamM; self.updatedAt = updatedAt
    }

    /// Bản mặc định lấy ROI / ngưỡng capo / h_cam từ default.json, chưa có f tay.
    public static func defaults(from cfg: AppConfig, deviceModel: String, lens: String,
                                frameWidth: Double, frameHeight: Double) -> DeviceCalibration {
        DeviceCalibration(deviceModel: deviceModel, lens: lens, frameWidth: frameWidth, frameHeight: frameHeight,
                          roi: cfg.roi.polygon, maxWidthRatio: cfg.detection.maxWidthRatio,
                          maxBottomRatio: cfg.detection.maxBottomRatio, hCamM: cfg.camera.hCamM)
    }

    public var storageKey: String {
        "calib.\(deviceModel).\(lens).\(Int(frameWidth))x\(Int(frameHeight))"
    }

    /// Chọn f cho frame: f tay > intrinsics > HFOV > config. Mọi giá trị đã ở hệ pixel của frame đang xử lý.
    public func resolveF(frameWidth w: Double, intrinsicsFx: Double?, hfovF: Double?,
                         config cfg: AppConfig) -> (f: Double, source: FocalSource) {
        if let m = manualFPx, m > 0 {
            return (Distance.scaleFToFrame(fPx: m, fImageWidth: frameWidth, frameWidth: w), .manual)
        }
        if let fx = intrinsicsFx, fx > 0 { return (fx, .intrinsics) }
        if let f = hfovF, f > 0 { return (f, .hfov) }
        return (Distance.scaleFToFrame(fPx: cfg.camera.fPx, fImageWidth: cfg.camera.fPxImageWidth, frameWidth: w), .config)
    }

    /// Config dùng cho Pipeline: ghi đè f, ROI, ngưỡng capo, h_cam bằng giá trị của máy này.
    public func apply(to cfg: AppConfig, fPx: Double, frameWidth w: Double) -> AppConfig {
        var c = cfg
        c.camera.fPx = fPx
        c.camera.fPxImageWidth = w
        c.camera.hCamM = hCamM
        c.roi.polygon = roi
        c.detection.maxWidthRatio = maxWidthRatio
        c.detection.maxBottomRatio = maxBottomRatio
        return c
    }
}

// Chế độ thu dữ liệu (docs/DRIVER_ASSIST.md, A6): khi nào lưu ảnh và nhãn gán sẵn theo định dạng YOLO
// để mở trong CVAT / Label Studio, sửa rồi train thêm trên Mac.
import Foundation

public enum YOLOLabel {
    /// Thứ tự lớp trong classes.txt của gói xuất. Thêm lớp mới (biển báo...) vào CUỐI để không lệch chỉ số cũ.
    public static let classes = ["car", "truck", "bus", "motorcycle", "traffic light"]

    /// Một dòng "class cx cy w h" (chuẩn hoá 0..1), nil nếu lớp không có trong danh sách hoặc box rỗng.
    public static func line(_ d: Detection, frameWidth w: Double, frameHeight h: Double,
                            classes: [String] = YOLOLabel.classes) -> String? {
        guard let c = classes.firstIndex(of: d.cls), w > 0, h > 0 else { return nil }
        let x1 = max(0, min(w, d.x1)), x2 = max(0, min(w, d.x2))
        let y1 = max(0, min(h, d.y1)), y2 = max(0, min(h, d.y2))
        guard x2 > x1, y2 > y1 else { return nil }
        func f(_ v: Double) -> String { String(format: "%.6f", v) }
        return "\(c) \(f((x1 + x2) / 2 / w)) \(f((y1 + y2) / 2 / h)) \(f((x2 - x1) / w)) \(f((y2 - y1) / h))"
    }

    public static func file(_ dets: [Detection], frameWidth w: Double, frameHeight h: Double) -> String {
        dets.compactMap { line($0, frameWidth: w, frameHeight: h) }.map { $0 + "\n" }.joined()
    }
}

/// Lưu ảnh mỗi `movingIntervalS` khi xe chạy; khi thấy đèn thì dày hơn (`lightIntervalS`), kể cả lúc đứng chờ đèn.
/// Đứng yên không có đèn thì không lưu (ảnh trùng nhau, tốn chỗ).
public struct CapturePolicy: Equatable, Sendable {
    public var movingIntervalS = 2.0
    public var lightIntervalS = 1.0
    public var minSpeedKmh = 5.0
    /// Giới hạn số ảnh mỗi phiên (~250 KB/ảnh → ~1 GB).
    public var maxImages = 4000
    public private(set) var lastT: Double?
    public private(set) var count = 0

    public init() {}

    public mutating func shouldCapture(t: Double, speedKmh: Double?, hasLight: Bool) -> Bool {
        guard count < maxImages else { return false }
        let moving = (speedKmh ?? 0) >= minSpeedKmh
        guard moving || hasLight else { return false }
        let interval = hasLight ? lightIntervalS : movingIntervalS
        if let last = lastT, t - last < interval, t >= last { return false }
        lastT = t
        count += 1
        return true
    }
}

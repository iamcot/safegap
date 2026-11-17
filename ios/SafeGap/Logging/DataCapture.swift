// Chế độ thu dữ liệu (docs/DRIVER_ASSIST.md, A6): lưu ảnh frame + nhãn gán sẵn (YOLO) + meta (GPS, giờ, tốc độ)
// vào Documents/captures/<phiên>/ để tối xuất ra gán nhãn (CVAT / Label Studio) và train thêm trên Mac.
// Cấu trúc mỗi phiên: images/*.jpg, labels/*.txt (cùng tên), classes.txt, meta.jsonl.
// Ảnh chỉ nằm trên máy cho tới khi người dùng tự bấm chia sẻ.
import CoreImage
import CoreVideo
import Foundation
import SafeGapCore
import UIKit

final class DataCapture {
    struct Meta: Encodable {
        var file: String
        var time: String
        var t: Double
        var speedKmh: Double?
        var lat: Double?
        var lon: Double?
        var courseDeg: Double?
        var light: String?
        var thermal: String
        /// Số biển model biển thấy trong ảnh (trang gán nhãn đánh dấu ảnh có biển).
        var signs: Int?
    }

    private let queue = DispatchQueue(label: "safegap.capture", qos: .utility)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var sessionDir: URL?
    private var policy = CapturePolicy()
    private let lock = NSLock()
    private var pending = 0
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var capturesDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("captures", isDirectory: true)
    }

    var isRunning: Bool { sessionDir != nil }

    /// Gọi trên hàng đợi camera.
    func start() {
        guard sessionDir == nil else { return }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let dir = Self.capturesDirectory.appendingPathComponent("capture_\(fmt.string(from: Date()))", isDirectory: true)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
            try fm.createDirectory(at: dir.appendingPathComponent("labels"), withIntermediateDirectories: true)
            try Data(YOLOLabel.classes.joined(separator: "\n").appending("\n").utf8)
                .write(to: dir.appendingPathComponent("classes.txt"))
            sessionDir = dir
            policy = CapturePolicy()
        } catch {
            sessionDir = nil
        }
    }

    func stop() { sessionDir = nil }

    /// Gọi mỗi frame đã xử lý (hàng đợi camera). Tự quyết có lưu không theo CapturePolicy.
    func offer(_ pb: CVPixelBuffer, t: Double, frameWidth w: Double, frameHeight h: Double, detections: [Detection],
               speed: SpeedProvider.Reading?, speedKmh: Double?, light: LightColor?, thermal: ThermalLevel,
               signCount: Int = 0) {
        guard let dir = sessionDir,
              policy.shouldCapture(t: t, speedKmh: speedKmh, hasLight: light != nil, hasSign: signCount > 0) else { return }
        // Ghi đĩa chậm hơn tốc độ lưu: bỏ ảnh này thay vì dồn hàng (giữ RAM thấp).
        lock.lock()
        let busy = pending >= 3
        lock.unlock()
        guard !busy else { return }
        // Chụp sang CGImage ngay (buffer camera sẽ bị dùng lại), nén JPEG ở hàng đợi riêng.
        guard let cg = ciContext.createCGImage(CIImage(cvPixelBuffer: pb), from: CGRect(x: 0, y: 0, width: w, height: h))
        else { return }
        let name = String(format: "%010.2f", t).replacingOccurrences(of: ".", with: "_")
        let labels = YOLOLabel.file(detections, frameWidth: w, frameHeight: h)
        let meta = Meta(file: name + ".jpg", time: iso.string(from: Date()), t: t, speedKmh: speedKmh,
                        lat: speed?.lat, lon: speed?.lon, courseDeg: speed?.courseDeg, light: light?.rawValue,
                        thermal: thermal.rawValue, signs: signCount > 0 ? signCount : nil)
        lock.lock()
        pending += 1
        lock.unlock()
        queue.async { [weak self] in
            defer {
                self?.lock.lock()
                self?.pending -= 1
                self?.lock.unlock()
            }
            guard let jpg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.75) else { return }
            try? jpg.write(to: dir.appendingPathComponent("images/\(name).jpg"))
            try? Data(labels.utf8).write(to: dir.appendingPathComponent("labels/\(name).txt"))
            if let line = try? JSONEncoder().encode(meta) {
                Self.append(line + Data("\n".utf8), to: dir.appendingPathComponent("meta.jsonl"))
            }
        }
    }

    private static func append(_ data: Data, to url: URL) {
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Các phiên đã lưu, mới nhất trước: (thư mục, số ảnh, dung lượng byte).
    static func sessions() -> [(url: URL, images: Int, bytes: Int)] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: capturesDirectory, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { $0.lastPathComponent.hasPrefix("capture_") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { dir in
                var images = 0, bytes = 0
                if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let u as URL in e {
                        bytes += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
                        if u.pathExtension == "jpg" { images += 1 }
                    }
                }
                return (dir, images, bytes)
            }
    }

    /// Nén một phiên thành .zip (dùng NSFileCoordinator .forUploading, có sẵn trên iOS) để chia sẻ.
    static func zip(_ dir: URL) -> URL? {
        var out: URL?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [.forUploading], error: &err) { tmp in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(dir.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: tmp, to: dest)) != nil { out = dest }
        }
        return out
    }
}

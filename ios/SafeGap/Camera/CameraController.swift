// Camera sau 1x, 1080p, tắt chống rung, bật intrinsics mỗi frame (SafeGap.md mục 4, Phase 2).
// App chạy màn hình ngang (cả hai chiều). Buffer xoay 0° hoặc 180° theo hướng cầm để ảnh luôn đúng chiều;
// toạ độ box, ROI, vạch làn đều theo ảnh đã xoay.
import AVFoundation
import CoreMedia
import simd

enum CameraError: LocalizedError {
    case notAuthorized, noCamera, cannotAddInput, cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Chưa cho phép dùng camera. Vào Cài đặt > Lái mới > Camera."
        case .noCamera: return "Không tìm thấy camera sau 1x."
        case .cannotAddInput, .cannotAddOutput: return "Không cấu hình được camera."
        }
    }
}

final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Cố định để f không đổi giữa các lần chạy. Đổi ở đây thì hiệu chỉnh lưu theo khoá mới.
    /// Khoá hiệu chỉnh theo ống kính: 1x hoặc zoom 2x (crop trên camera chính, máy nào cũng có).
    static func lens(zoom: Double) -> String { zoom > 1.01 ? "wide2x" : "wide1x" }
    static let frameWidth = 1920.0
    static let frameHeight = 1080.0

    let session = AVCaptureSession()
    let frameQueue = DispatchQueue(label: "safegap.camera.frames", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "safegap.camera.session")
    private let output = AVCaptureVideoDataOutput()
    private var configured = false

    /// Gọi trên frameQueue cho từng frame.
    var onFrame: ((CMSampleBuffer) -> Void)?
    /// HFOV (độ) của định dạng đang dùng, để tính f dự phòng.
    private(set) var hfovDeg: Double?
    private(set) var intrinsicsSupported = false
    private(set) var stabilizationOff = false

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Cấu hình + chạy. completion trả lỗi (nếu có) trên main.
    func start(completion: @escaping (Error?) -> Void) {
        sessionQueue.async {
            do {
                if !self.configured {
                    try self.configure()
                    self.configured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
        session.addOutput(output)

        if let conn = output.connection(with: .video) {
            if conn.isCameraIntrinsicMatrixDeliverySupported {
                conn.isCameraIntrinsicMatrixDeliveryEnabled = true
                intrinsicsSupported = true
            }
            if conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = .off  // chống rung crop/biến dạng ảnh làm lệch f
            }
            stabilizationOff = true
            if conn.isVideoRotationAngleSupported(0) { conn.videoRotationAngle = 0 }
        }

        try device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .far }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.videoZoomFactor = 1.0
        device.unlockForConfiguration()
        hfovDeg = Double(device.activeFormat.videoFieldOfView)
    }

    /// Đổi fps của camera (giảm khi máy nóng). Kẹp trong khoảng định dạng hỗ trợ, tối đa 30.
    func setFrameRate(_ fps: Double) {
        sessionQueue.async {
            guard let input = self.session.inputs.first as? AVCaptureDeviceInput else { return }
            let device = input.device
            let ranges = device.activeFormat.videoSupportedFrameRateRanges
            let lo = ranges.map(\.minFrameRate).min() ?? 1
            let hi = min(ranges.map(\.maxFrameRate).max() ?? 30, 30)
            let f = min(max(fps, lo), hi)
            let d = CMTime(value: 1000, timescale: CMTimeScale((f * 1000).rounded()))
            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = d
                device.activeVideoMaxFrameDuration = d
                device.unlockForConfiguration()
            } catch {
                // không đổi được fps camera thì FrameProcessor vẫn bỏ bớt frame
            }
        }
    }

    /// Xoay buffer theo hướng cầm máy (0° hoặc 180°), để app dùng được cả hai kiểu nằm ngang.
    func setRotation(_ angle: CGFloat) {
        sessionQueue.async {
            guard let conn = self.output.connection(with: .video), conn.isVideoRotationAngleSupported(angle),
                  conn.videoRotationAngle != angle else { return }
            conn.videoRotationAngle = angle
        }
    }

    /// Zoom số trên camera chính (1 hoặc 2). Xe ở xa to gấp đôi trên ảnh → đo xa chính xác hơn, đổi lại nhìn hẹp hơn.
    func setZoom(_ z: Double) {
        sessionQueue.async {
            guard let input = self.session.inputs.first as? AVCaptureDeviceInput else { return }
            let device = input.device
            let zz = min(max(z, 1), device.activeFormat.videoMaxZoomFactor)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = zz
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }

    /// fx, cy (pixel) từ cameraIntrinsicMatrix gắn kèm frame. Hệ pixel = kích thước buffer.
    static func intrinsics(_ sb: CMSampleBuffer) -> (fx: Double, cy: Double)? {
        guard let att = CMGetAttachment(sb, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil),
              let data = att as? Data, data.count >= MemoryLayout<matrix_float3x3>.size else { return nil }
        let m = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
        let fx = Double(m.columns.0.x)
        return fx > 0 ? (fx, Double(m.columns.2.y)) : nil
    }
}

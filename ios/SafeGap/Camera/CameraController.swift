// Camera sau 1x, 1080p, tắt chống rung, bật intrinsics mỗi frame (SafeGap.md mục 4, Phase 2).
// Không xoay buffer: app khoá màn hình ngang (landscapeRight), đúng hướng gốc của cảm biến,
// nên toạ độ box, ROI và ma trận intrinsics cùng một hệ pixel.
import AVFoundation
import CoreMedia
import simd

enum CameraError: LocalizedError {
    case notAuthorized, noCamera, cannotAddInput, cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Chưa cho phép dùng camera. Vào Cài đặt > SafeGap > Camera."
        case .noCamera: return "Không tìm thấy camera sau 1x."
        case .cannotAddInput, .cannotAddOutput: return "Không cấu hình được camera."
        }
    }
}

final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Cố định để f không đổi giữa các lần chạy. Đổi ở đây thì hiệu chỉnh lưu theo khoá mới.
    static let lens = "wide1x"
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

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }

    /// fx (pixel) từ cameraIntrinsicMatrix gắn kèm frame. Hệ pixel = kích thước buffer.
    static func intrinsicsFx(_ sb: CMSampleBuffer) -> Double? {
        guard let att = CMGetAttachment(sb, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil),
              let data = att as? Data, data.count >= MemoryLayout<matrix_float3x3>.size else { return nil }
        let m = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
        let fx = Double(m.columns.0.x)
        return fx > 0 ? fx : nil
    }
}

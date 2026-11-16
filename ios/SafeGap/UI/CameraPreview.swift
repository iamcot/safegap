import AVFoundation
import SwiftUI
import UIKit

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    /// Ngang kiểu landscapeRight = hướng gốc cảm biến → 0°. Lật ngược (landscapeLeft) → 180°.
    var rotationAngle: CGFloat {
        window?.windowScene?.interfaceOrientation == .landscapeLeft ? 180 : 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let a = rotationAngle
        if let c = previewLayer.connection, c.isVideoRotationAngleSupported(a), c.videoRotationAngle != a {
            c.videoRotationAngle = a
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {
        v.setNeedsLayout()
    }
}

/// View rỗng chỉ để biết máy đang nằm ngang chiều nào, kể cả khi ẩn hình camera.
struct OrientationReader: UIViewRepresentable {
    var onRotation: (CGFloat) -> Void

    final class V: UIView {
        var onRotation: ((CGFloat) -> Void)?
        private var last: CGFloat?
        override func layoutSubviews() {
            super.layoutSubviews()
            let a: CGFloat = window?.windowScene?.interfaceOrientation == .landscapeLeft ? 180 : 0
            if a != last { last = a; onRotation?(a) }
        }
        override func didMoveToWindow() { super.didMoveToWindow(); setNeedsLayout() }
    }

    func makeUIView(context: Context) -> V {
        let v = V(); v.isUserInteractionEnabled = false; v.onRotation = onRotation; return v
    }
    func updateUIView(_ v: V, context: Context) { v.onRotation = onRotation; v.setNeedsLayout() }
}
